# Research: FinOps - 2026-03-04

**Time:** 0752 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution for Native Apps + shared warehouses)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for chargeback/showback is **object tags** for resources/users and **query tags** when an application runs queries on behalf of many cost centers. This enables attribution by department/project/environment. [1]
2. In a single account, SQL-based cost attribution by tags uses `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (what is tagged), `...WAREHOUSE_METERING_HISTORY` (warehouse credits), and `...QUERY_ATTRIBUTION_HISTORY` (per-query compute credits). `QUERY_ATTRIBUTION_HISTORY` has **no organization-wide equivalent** in `ORGANIZATION_USAGE`. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` attributes **warehouse compute credits per query**, excluding warehouse idle time and excluding other cost dimensions (storage, data transfer, serverless features, cloud services, AI tokens). Latency can be **up to 8 hours**, and short queries (≈<=100ms) are not included. [2]
4. For broader compute cost exploration, Snowflake provides `ACCOUNT_USAGE` and `ORGANIZATION_USAGE` views; to express costs in currency (not just credits), Snowflake recommends querying `USAGE_IN_CURRENCY_DAILY`. [3]
5. There is a dedicated cost view `APPLICATION_DAILY_USAGE_HISTORY` (in `ACCOUNT_USAGE`) for **Snowflake Native Apps daily credit usage** (warehouses/serverless/cloud services at the “application” level). [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to objects (domain + object identifiers). Used to attribute warehouse/user costs by tag. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits consumed by warehouses (includes cloud services associated with warehouse usage). [1][3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits attributed (no idle); latency up to 8h; excludes short queries (~<=100ms). [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Contains `QUERY_TAG` and other dimensions for query activity (useful to enrich/parse tags). [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to determine billed cloud services adjustment (cloud services billed only if >10% of warehouse usage). [3] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide warehouse credit usage. For org-level reporting of warehouse costs. [1][3] |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Daily credit usage for Snowflake Native Apps within an account (last 365 days). [3] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Converts credits to currency using daily credit price. (No per-query equivalent.) [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost Attribution Starter Kit” pack**: ship a single stored procedure + views that (a) validates tagging coverage for `USER` and `WAREHOUSE` domains via `TAG_REFERENCES`, and (b) produces daily rollups by `COST_CENTER` and `QUERY_TAG` using `QUERY_ATTRIBUTION_HISTORY` + `WAREHOUSE_METERING_HISTORY`. (This is directly aligned with Snowflake’s documented recommended approach.) [1][2]
2. **Native App daily cost card**: add a dashboard widget and a backing view that reads `APPLICATION_DAILY_USAGE_HISTORY` to show the app’s daily credits (and optionally estimate currency by joining to `USAGE_IN_CURRENCY_DAILY` at day granularity). [3]
3. **Idle-time allocation toggle**: provide two views: (a) “pure attributed query cost” from `QUERY_ATTRIBUTION_HISTORY`, and (b) “fully-loaded warehouse cost” that allocates idle time back to tags proportionally (pattern is documented by Snowflake). [1][2]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily cost by query_tag with optional idle allocation

This is a *drop-in* pattern for the Native App (or an admin repo) to compute cost by tag for the last 30 days.

```sql
-- Purpose:
-- 1) Summarize per-query compute credits by QUERY_TAG (excludes idle) using QUERY_ATTRIBUTION_HISTORY.
-- 2) Optionally allocate warehouse idle cost proportionally back to tags (aka “fully-loaded”).
--
-- Notes from Snowflake docs:
-- - QUERY_ATTRIBUTION_HISTORY excludes warehouse idle time; latency can be up to 8 hours; short queries (~<=100ms) are excluded. [2]
-- - WAREHOUSE_METERING_HISTORY is warehouse-level credits; can be used to allocate idle. [1][3]

-- Time window
SET start_ts = DATEADD(day, -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

WITH
-- (A) Per-query attributed compute credits by tag (excludes idle)
q_tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_norm,
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_attributed_compute) AS attributed_compute_credits,
    SUM(credits_used_query_acceleration) AS attributed_qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts AND start_time < $end_ts
  GROUP BY 1, 2
),

-- (B) Warehouse billed credits over same window (includes idle at warehouse level)
wh_credits AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_used_compute) AS wh_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts AND start_time < $end_ts
  GROUP BY 1
),

-- (C) Total attributed credits per day (denominator for proportional idle allocation)
q_tag_totals AS (
  SELECT
    usage_date,
    SUM(attributed_compute_credits) AS total_attributed_compute_credits
  FROM q_tag_credits
  GROUP BY 1
)

SELECT
  q.usage_date,
  q.query_tag_norm AS query_tag,
  q.attributed_compute_credits,
  q.attributed_qas_credits,

  -- Fully-loaded compute credits = (tag share of attributed credits) * warehouse credits.
  -- This follows Snowflake’s published examples that distribute idle proportionally. [1]
  IFF(t.total_attributed_compute_credits = 0,
      NULL,
      (q.attributed_compute_credits / t.total_attributed_compute_credits) * w.wh_compute_credits
  ) AS fully_loaded_compute_credits

FROM q_tag_credits q
JOIN q_tag_totals t
  ON q.usage_date = t.usage_date
LEFT JOIN wh_credits w
  ON q.usage_date = w.usage_date
ORDER BY q.usage_date DESC, attributed_compute_credits DESC;
```

### ADR Sketch: Dual-lane cost attribution for Native App

```text
Title: Dual-lane cost attribution (Application-level + Query-level)

Context:
- Snowflake provides APPLICATION_DAILY_USAGE_HISTORY for Native App daily credit usage. [3]
- Query-level compute attribution is available via QUERY_ATTRIBUTION_HISTORY but excludes idle time and has latency. [2]
- Organization-wide query attribution is not available (no ORG_USAGE equivalent). [1]

Decision:
- Lane 1 (App-level): use APPLICATION_DAILY_USAGE_HISTORY for “What did the app cost per day?”
- Lane 2 (Workload-level): use QUERY_ATTRIBUTION_HISTORY (optionally allocating idle via WAREHOUSE_METERING_HISTORY) for “What workloads/cost-centers drove compute?”

Consequences:
- Best-effort currency conversion is day-granular via USAGE_IN_CURRENCY_DAILY. [3]
- Query-level dashboards must clearly label exclusions: idle/serverless/storage/transfer/etc. [2]
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` latency (up to 8h) means near-real-time dashboards may look “low” | Users lose trust in dashboards | Use banner + “data freshness” indicator; compare totals to `WAREHOUSE_METERING_HISTORY` daily. [2] |
| Per-query attribution excludes idle time and short queries (~<=100ms) | Understates some workloads; can bias attribution | Offer two modes: attributed-only vs fully-loaded idle allocation. [1][2] |
| No org-wide `QUERY_ATTRIBUTION_HISTORY` | Multi-account org rollups can’t be query-granular centrally | For org rollups, rely on `ORGANIZATION_USAGE` warehouse usage + tagging; keep query-granular within each account. [1][3] |
| `APPLICATION_DAILY_USAGE_HISTORY` provides app-level totals but may not map cleanly to internal cost centers | Hard to do chargeback purely from app-level view | Combine app-level totals with query tags/object tags strategy for internal allocation. [1][3] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — QUERY_ATTRIBUTION_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Exploring compute cost (includes `APPLICATION_DAILY_USAGE_HISTORY`, `USAGE_IN_CURRENCY_DAILY`): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Snowflake Docs — QUERY_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Decide a default: attributed-only vs fully-loaded (idle allocated) for the product’s “Top cost centers” widget.
- Validate the exact schema/columns for `APPLICATION_DAILY_USAGE_HISTORY` and whether it can be enriched with app identifiers that match Native App package/application names.
- Add a test dataset + “expected totals” checks: daily sum(by query_tag fully-loaded) ~= daily warehouse credits (within rounding), to catch data gaps/lag.
