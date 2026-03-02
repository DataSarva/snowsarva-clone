# Research: FinOps - 2026-03-02

**Time:** 1905 UTC  
**Topic:** finops  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (QAH) provides *per-query* compute credits (`CREDITS_ATTRIBUTED_COMPUTE`) for queries executed on warehouses in the account; it explicitly **excludes warehouse idle time**. It also exposes `QUERY_TAG`, `QUERY_HASH`, and `QUERY_PARAMETERIZED_HASH` for grouping/attribution. ([Snowflake docs: ACCOUNT_USAGE QAH](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history))
2. QAH attribution is based on a **weighted average of resource consumption during time intervals** for concurrently executing queries; **short-running queries (~<=100ms)** are not included. Data latency can be **up to ~8 hours** for `ACCOUNT_USAGE`. ([Snowflake docs: ACCOUNT_USAGE QAH](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history))
3. Snowflake’s recommended tagging-based cost attribution pattern combines:
   - object tags (e.g., tag warehouses/users) via `TAG_REFERENCES`
   - metered warehouse credits via `WAREHOUSE_METERING_HISTORY`
   - query-attributed credits via `QUERY_ATTRIBUTION_HISTORY`
   and provides example SQL for distributing **idle time** proportionally back across users/tags by scaling query-attributed credits up to match metered credits. ([Snowflake docs: Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing))
4. An organization-level QAH exists as a **premium** `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` view (organization account; Enterprise Edition+), with **potentially longer latency (up to 24h)** and extra org/account columns. This enables cross-account query cost analysis (subject to edition / org account availability). ([Snowflake docs: ORG_USAGE QAH](https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history))
5. Third-party practitioners have reported practical issues/oddities with QAH in some accounts (e.g., surprising/“inflated” per-query attributions vs expectation; and/or join mismatches when validating against `QUERY_HISTORY` + `WAREHOUSE_METERING_HISTORY`). Treat QAH as authoritative for *Snowflake-provided* per-query compute attribution, but validate reconciliation to metered credits and sanity-check for your environment. ([Greybeam blog](https://blog.greybeam.ai/snowflake-cost-per-query/))

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits; includes `QUERY_TAG`; excludes idle; latency up to ~8h; short queries excluded. ([docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Metered warehouse compute credits on hourly grain; good reconciliation target for “what you were billed/metred for warehouses”. (Referenced in cost attribution guide: [docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps object_id/object_name/domain → tags; used to attribute warehouses/users to cost centers. ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Used to find `ROOT_QUERY_ID` for stored procedures / hierarchical queries in QAH examples. ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ORG_USAGE` (premium) | Org-wide per-query compute attribution; org account; Enterprise+; latency up to 24h. ([docs](https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history)) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Reconciled per-query cost model (native app “truth table”)**: build a canonical dataset that produces both:
   - *query attributed credits* (from QAH)
   - *metered credits* (from WAREHOUSE_METERING_HISTORY)
   - *idle credits* (metered − attributed)
   and then allocates idle credits back to tags/users (configurable strategies).
2. **Cost allocation modes** in app UI/API:
   - “Execution-only” mode = pure QAH (exclude idle)
   - “Fully-loaded” mode = scale/allocate idle proportionally so totals match metered credits (Snowflake’s documented approach).
3. **Data quality checks + explainability**:
   - daily reconciliation report by warehouse/day: metered vs attributed vs idle
   - flag warehouses where attributed > metered, or where attributed/metered ratio is “implausible” (env-specific threshold)
   - highlight potential causes: short queries excluded, QAH latency, multi-cluster scaling effects.

## Concrete Artifacts

### Artifact: “Fully-loaded credits by query_tag” (execution + allocated idle)

Goal: produce a table for the native app that answers:
- “credits_execution” (from QAH)
- “credits_fully_loaded” (execution scaled up to include idle, distributed proportional to execution)

This is essentially Snowflake’s documented approach for tags, but packaged as a reusable view/query for a native app pipeline.

```sql
-- Fully-loaded credits by query tag for a time window.
-- Approach: scale query-attributed credits (execution-only) so that the sum equals metered warehouse credits.
-- This allocates idle time proportionally to the execution-only credits.
--
-- Sources:
--  - QAH semantics + idle exclusion: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
--  - documented scaling approach: https://docs.snowflake.com/en/user-guide/cost-attributing

-- Parameters (adapt for your app)
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

WITH
-- Metered warehouse credits (what warehouses consumed on the hourly grain)
wh_metered AS (
  SELECT
    DATE_TRUNC('day', start_time) AS day,
    SUM(credits_used_compute) AS metered_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1
),

-- Execution-only credits attributed to queries (excludes idle)
tag_exec AS (
  SELECT
    DATE_TRUNC('day', start_time) AS day,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS exec_credits,
    SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1, 2
),

exec_totals AS (
  SELECT day, SUM(exec_credits) AS exec_credits_all_tags
  FROM tag_exec
  GROUP BY 1
)

SELECT
  t.day,
  t.query_tag,
  t.exec_credits,
  t.qas_credits,
  m.metered_credits,

  -- Fully-loaded credits (execution scaled to include idle)
  -- If exec total is 0 (e.g., latency, no qualifying queries), emit NULL to avoid divide-by-zero.
  CASE
    WHEN e.exec_credits_all_tags = 0 THEN NULL
    ELSE (t.exec_credits / e.exec_credits_all_tags) * m.metered_credits
  END AS fully_loaded_credits,

  -- Observability columns
  (m.metered_credits - e.exec_credits_all_tags) AS idle_credits_estimate

FROM tag_exec t
JOIN exec_totals e
  ON t.day = e.day
JOIN wh_metered m
  ON t.day = m.day
ORDER BY t.day DESC, fully_loaded_credits DESC;
```

**Notes for productization (native app):**
- This is *account-level*; org-level versions should swap to `SNOWFLAKE.ORGANIZATION_USAGE.*` views (and include `ACCOUNT_LOCATOR`/`ACCOUNT_NAME` groupings) when available. ([ORG_USAGE QAH docs](https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history))
- QAH latency means the most recent hours may undercount; the pipeline should watermark (e.g., process up to NOW()-10h) or mark “data freshness” in the UI. ([ACCOUNT_USAGE QAH docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history))

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| QAH excludes idle time and short queries, and has latency (up to ~8h) | Recent windows may mislead; users may expect reconciliation to metered credits to match immediately | Implement freshness watermark + reconciliation report; document in UI. ([QAH docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)) |
| “Fully-loaded scaling” assumes idle should be allocated proportional to execution credits | May be politically contentious (some teams argue idle is “owner’s responsibility”) | Make allocation strategy configurable (e.g., proportional; warehouse-owner; or leave idle unallocated). Scaling approach is documented by Snowflake. ([Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| ORG_USAGE QAH is premium / org account only | Cross-account cost allocation may not be available for all customers | Detect availability at install-time; degrade gracefully to per-account mode. ([ORG_USAGE QAH docs](https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history)) |
| Practitioner reports suggest QAH may behave unexpectedly in some accounts | Incorrect insights if treated as infallible | Add “sanity checks” + “report anomaly” flow; keep reconciliation logic grounded in `WAREHOUSE_METERING_HISTORY`. ([Greybeam](https://blog.greybeam.ai/snowflake-cost-per-query/)) |

## Links & Citations

1. Snowflake docs — `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. Snowflake docs — Attributing cost (tags + example SQL patterns): https://docs.snowflake.com/en/user-guide/cost-attributing
3. Snowflake docs — `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (premium/org account): https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history
4. Greybeam — Deep Dive: Snowflake Query Cost + Idle attribution (practitioner notes/caveats): https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Turn the artifact query into a versioned native-app view (e.g., `COST_INTEL.V1.FULLY_LOADED_CREDITS_BY_TAG_DAILY`) plus a reconciliation view by warehouse/day.
- Define allocation strategies as a config table (per account): `{strategy: PROPORTIONAL | WAREHOUSE_OWNER | UNALLOCATED}`.
- Add a “freshness watermark” policy to all QAH-derived datasets (default: `now() - 10 hours`) and surface it in the UI.
