# Research: FinOps - 2026-03-02

**Time:** 14:43 UTC  
**Topic:** Cost attribution primitives (object tags + query tags) → app-ready attribution model  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for internal cost attribution is: (a) **object tags** on resources/users for ownership, and (b) **query tags** for workloads where an app runs queries on behalf of multiple cost centers. (Snowflake docs) [1]
2. Within a single account, Snowflake documents cost-attribution queries that join:
   - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (what is tagged)
   - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (metered credits by warehouse, hourly)
   - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute credits; **excludes idle time**) [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` has documented limitations: latency up to ~8 hours; short-running queries (≈<=100ms) are excluded; `CREDITS_ATTRIBUTED_COMPUTE` is query execution only and does **not** include warehouse idle time. (Snowflake docs) [2]
4. Snowflake object tags support inheritance and can be queried with `apply_method` via `TAG_REFERENCES`-family views/functions to determine whether a tag was manually set vs inherited/propagated. (Snowflake docs) [3]
5. Third-party practitioners have observed potential discrepancies when validating `QUERY_ATTRIBUTION_HISTORY` vs metered warehouse credits (e.g., surprising attribution for short queries), and recommend reconciling against `WAREHOUSE_METERING_HISTORY` and/or using custom attribution that accounts for idle time. (Greybeam blog; not authoritative—treat as a validation prompt) [4]
6. Snowflake has announced “tag-based budgets” that leverage object tags to define the scope of budget monitoring (budget tracks costs of all objects sharing a tag, including via inheritance). (Snowflake engineering blog) [5]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Identifies tagged objects/users; join key varies by `domain` (e.g., `WAREHOUSE` uses `object_id` = `warehouse_id` in metering history). [1][3] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly metered compute credits per warehouse (`credits_used_compute`). Used as reconciliation source for compute spend. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits (`credits_attributed_compute`) excluding idle time; includes autoscaling/resizing effects; short queries excluded; latency up to ~8h. [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | ACCOUNT_USAGE | Can be used to find `root_query_id` for stored procedures, then sum costs across hierarchical queries. [2] |
| `my_db.INFORMATION_SCHEMA.TAG_REFERENCES()` | Function | INFO_SCHEMA | Example function to inspect tag association + `apply_method` in a DB scope. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution “coverage” dashboard**: show % of warehouse credits attributable by (a) tagged warehouses, (b) tagged users, (c) query_tag, and (d) “untagged/unknown” buckets. This directly operationalizes Snowflake’s own examples and surfaces governance gaps.
2. **Idle-time aware tag attribution (optional mode)**: implement Snowflake’s documented proportional redistribution pattern for idle time (compute metered credits vs sum of per-query credits), producing “with idle” and “without idle” reports.
3. **Tag lineage + precedence explainer**: for any object contributing to a cost center, display how the tag was applied (manual vs inheritance vs propagation) using `apply_method` and/or lineage views. This reduces “why is this tagged?” confusion.

## Concrete Artifacts

### Cost attribution fact model (app-ready) + reference SQL

Goal: produce a durable, queryable fact table keyed by day/hour + attribution dimension (tag value / query_tag / user tag), with explicit separation of **metered credits** vs **attributed execution credits** vs **idle-redistributed credits**.

#### Proposed schema (logical)

```text
FINOPS.ATTRIBUTION_FACT_HOURLY
  - hour_ts                      TIMESTAMP_LTZ  -- hour bucket
  - warehouse_id                 NUMBER
  - warehouse_name               VARCHAR
  - attribution_type             VARCHAR         -- 'WAREHOUSE_TAG' | 'USER_TAG' | 'QUERY_TAG'
  - tag_name                     VARCHAR         -- e.g. 'COST_CENTER'
  - tag_value                    VARCHAR         -- e.g. 'finance' (or 'untagged')
  - query_tag                    VARCHAR         -- when attribution_type='QUERY_TAG' else NULL
  - execution_credits            NUMBER          -- sum(qah.credits_attributed_compute)
  - metered_credits              NUMBER          -- sum(whmh.credits_used_compute) at same grain
  - idle_credits_estimate        NUMBER          -- GREATEST(metered_credits - execution_credits_total, 0)
  - credits_with_idle_allocated  NUMBER          -- execution_credits + idle allocation
  - sample_size_queries          NUMBER
  - data_latency_note            VARCHAR         -- optional: e.g. 'ACCOUNT_USAGE up to 8h delay'
```

#### Reference SQL: per `QUERY_TAG` attribution with optional idle redistribution (monthly)

This is directly aligned with Snowflake’s documented “including idle time” pattern (using warehouse metering credits and proportionally redistributing idle based on execution credits). [1][2]

```sql
-- PARAMS
SET start_time = DATEADD(MONTH, -1, CURRENT_DATE());
SET end_time   = CURRENT_DATE();

WITH
-- 1) Metered credits (includes idle) from WAREHOUSE_METERING_HISTORY
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_time
    AND start_time <  $end_time
),

-- 2) Execution-attributed credits by QUERY_TAG (excludes idle)
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute)            AS execution_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_time
    AND start_time <  $end_time
  GROUP BY 1
),

-- 3) Total execution-attributed credits across all query tags
exec_total AS (
  SELECT SUM(execution_credits) AS exec_credits_total
  FROM tag_credits
)

SELECT
  tc.tag,
  tc.execution_credits,
  /* proportional idle redistribution; same idea as Snowflake docs */
  (tc.execution_credits / NULLIF(et.exec_credits_total, 0))
    * wb.compute_credits                                       AS credits_with_idle_allocated
FROM tag_credits tc
CROSS JOIN exec_total et
CROSS JOIN wh_bill wb
ORDER BY credits_with_idle_allocated DESC;
```

#### Notes for implementation

- `QUERY_ATTRIBUTION_HISTORY` is not guaranteed to reconcile “perfectly” with metered credits for every scenario; treat `WAREHOUSE_METERING_HISTORY` as the reconciliation anchor and compute “unattributed delta.” (Snowflake docs clearly say idle is excluded; third-party reports suggest further validation is needed.) [2][4]
- Build attribution layers as composable “views” in the native app so customers can choose “execution-only” vs “with idle allocated.”

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| `QUERY_ATTRIBUTION_HISTORY` coverage gaps (short queries excluded; latency) may distort attribution for workloads heavy in short queries. | Under-counted execution credits; higher “unattributed delta.” | Compare hourly sums vs `WAREHOUSE_METERING_HISTORY` and report coverage %. [2] |
| Proportional idle redistribution assumes idle should be allocated in proportion to execution credits. | Misalignment with internal chargeback policies; could be seen as unfair. | Make it a selectable policy (execution-only vs proportional idle vs “bill to owner of warehouse tag”). [1] |
| Tag inheritance/propagation may cause unexpected attribution scope. | Surprise budget/chargeback results. | Use `apply_method`/lineage reporting to explain tag origin. [3][5] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Introduction to object tagging: https://docs.snowflake.com/en/user-guide/object-tagging/introduction
4. Greybeam — Deep Dive: Snowflake's Query Cost and Idle Time Attribution: https://blog.greybeam.ai/snowflake-cost-per-query/
5. Snowflake Engineering Blog — Tag-based budgets & cost attribution: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Next Steps / Follow-ups

- Add a second artifact: an ADR for “Idle time allocation policies” (execution-only vs proportional vs warehouse-owner vs fixed overhead pool).
- Extend the model to **user-tag** attribution (join `TAG_REFERENCES` where `domain='USER'` to `QUERY_ATTRIBUTION_HISTORY.user_name`) to mirror Snowflake’s documented scenario. [1]
- Validate feasibility of hourly-grain fact build using only ACCOUNT_USAGE views (consider delays) and whether we need incremental backfill logic.
