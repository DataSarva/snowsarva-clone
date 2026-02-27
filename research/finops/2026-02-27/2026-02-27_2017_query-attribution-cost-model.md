# Research: FinOps - 2026-02-27

**Time:** 20:17 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits attributed** for queries run on warehouses in the last 365 days, enabling cost attribution by tag/user/query hash. The value includes execution credits (incl. resize/autoscale weighting) and **excludes warehouse idle time**. It also excludes non-warehouse costs (serverless, storage, data transfer, cloud services, AI tokens, etc.). [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly warehouse credits** and includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (execution-only) so the **difference vs `CREDITS_USED_COMPUTE`** can be used to estimate **idle compute credits** at a warehouse/hour grain. [2]
3. Snowflake’s documented, recommended cost attribution approach is to use **object tags** (warehouses/users/etc.) and **query tags** (per statement) and then join attribution/metering views with `ACCOUNT_USAGE.TAG_REFERENCES`. Within an org, `ORGANIZATION_USAGE` supports warehouse metering and tags, but **there is no org-wide equivalent of `QUERY_ATTRIBUTION_HISTORY`**. [3]
4. `QUERY_ATTRIBUTION_HISTORY` has **latency up to ~8 hours** and is readable by roles granted `USAGE_VIEWER` or `GOVERNANCE_VIEWER` database roles. [1]
5. The `2024-08-30` release note announces `QUERY_ATTRIBUTION_HISTORY` specifically for **warehouse cost for queries** and attribution by **tag, user, query hash**. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query credits for warehouse execution; excludes idle time + other cost categories; latency up to 8h. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse; `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` enable idle residual compute estimate. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to associate tag values with users/warehouses/etc for showback/chargeback queries. [3] |
| `QUERY_TAG` session parameter | Parameter | SQL | Query-level label that appears in attribution views; recommended for app/workflow attribution. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Per-query cost explorer (warehouse-only)**: A UI + API endpoint that filters `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG`, `USER_NAME`, `WAREHOUSE_NAME`, `QUERY_PARAMETERIZED_HASH`, and time range to surface top expensive query patterns.
2. **Idle compute allocation (optional, explicit toggle)**: Compute an hourly idle residual per warehouse from `WAREHOUSE_METERING_HISTORY` and allocate it across queries (or tags/users) proportionally to attributed execution credits for that same warehouse/hour.
3. **Tag hygiene report**: daily job that flags (a) top compute credits with `QUERY_TAG IS NULL` and (b) warehouses/users without required tags (via `TAG_REFERENCES`) to drive governance.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL: Cost by `QUERY_TAG` with optional idle allocation (warehouse compute only)

Goal: produce **credits by query_tag** for a time window, where you can optionally include an *allocated idle* component.

Notes:
- This is **compute credits** from warehouse usage only (not storage/serverless/etc.).
- Allocation is performed at `warehouse_name + hour` grain.
- If there are hours with metering but no attributed queries (e.g., truly idle), allocation will have no denominator and the idle stays unallocated (reported separately).

```sql
-- Inputs
SET start_ts = DATEADD('day', -7, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

-- 1) Hourly warehouse ledger: compute used vs compute attributed to query execution
WITH wh_hour AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attrib_queries,
    GREATEST(
      SUM(credits_used_compute) - SUM(credits_attributed_compute_queries),
      0
    ) AS credits_idle_est
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1,2
),

-- 2) Per-query attribution, bucketed to hour for joining
qah_hour AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    COALESCE(query_tag, 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS credits_attrib_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1,2,3
),

-- 3) Denominator: total attributed execution credits per warehouse/hour
qah_hour_tot AS (
  SELECT warehouse_name, hour_ts, SUM(credits_attrib_compute) AS credits_attrib_compute_total
  FROM qah_hour
  GROUP BY 1,2
),

-- 4) Allocate idle estimate proportionally to each tag's execution credits
alloc AS (
  SELECT
    q.warehouse_name,
    q.hour_ts,
    q.query_tag,
    q.credits_attrib_compute AS credits_exec,
    w.credits_idle_est,
    t.credits_attrib_compute_total,
    CASE
      WHEN t.credits_attrib_compute_total > 0
        THEN (q.credits_attrib_compute / t.credits_attrib_compute_total) * w.credits_idle_est
      ELSE 0
    END AS credits_idle_alloc
  FROM qah_hour q
  JOIN wh_hour w
    ON w.warehouse_name = q.warehouse_name
   AND w.hour_ts = q.hour_ts
  JOIN qah_hour_tot t
    ON t.warehouse_name = q.warehouse_name
   AND t.hour_ts = q.hour_ts
)

SELECT
  query_tag,
  SUM(credits_exec) AS credits_exec,
  SUM(credits_idle_alloc) AS credits_idle_alloc,
  SUM(credits_exec) + SUM(credits_idle_alloc) AS credits_total_incl_alloc_idle
FROM alloc
GROUP BY 1
ORDER BY credits_total_incl_alloc_idle DESC;

-- Optional: report unallocated idle (hours where qah attribution is missing)
-- (This can happen because of attribution latency, warehouse was idle without queries,
--  or edge cases where attributed execution credits don't line up with metering hour buckets.)
-- SELECT SUM(credits_idle_est) AS credits_idle_est_total
-- FROM wh_hour;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes idle + non-warehouse costs | “Cost per query” is not “total bill” (needs separate service-type + org currency integration) | Documented exclusions in view usage notes. [1] |
| Attribution latency up to ~8h | Recent hours can look “more idle” than reality (metering present, attribution not landed yet) | Documented latency; consider delaying allocation window or reprocessing last N hours daily. [1] |
| Hour bucketing can create small reconciliation gaps | Minor discrepancies between metering vs attribution totals; may confuse users | Explain the model; provide reconciliation views + residual line item. [2] |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` may exceed billed due to cloud services adjustment | Incorrect $ conversion if using raw `CREDITS_USED` | Use `METERING_DAILY_HISTORY` for billed credits when needed (per doc note). [2] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/user-guide/cost-attributing
4. https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution

## Next Steps / Follow-ups

- Convert the SQL draft into a **materialized daily fact table** in the Native App (e.g., `FINOPS__COST_BY_QUERY_TAG_DAILY`) and add a reconciliation dashboard (exec vs idle vs residual).
- Decide product semantics: default to **execution-only** (doc-aligned) and make idle allocation an explicit opt-in (with explanation).
- Add a backfill/recompute policy to handle attribution latency (e.g., reprocess last 48h nightly).
