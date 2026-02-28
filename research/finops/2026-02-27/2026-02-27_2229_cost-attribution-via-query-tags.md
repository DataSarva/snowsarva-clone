# Research: FinOps - 2026-02-27

**Time:** 22:29 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes a `QUERY_TAG` column that captures the query tag set for a statement via the `QUERY_TAG` session parameter. \[1]
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns hourly credit usage per warehouse and includes:
   - `CREDITS_USED_COMPUTE` (warehouse compute credits)
   - `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributed to queries; does **not** include warehouse idle time). \[2]
3. The account-level `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` view returns hourly credit usage across many service types (e.g., `WAREHOUSE_METERING`, `SERVERLESS_TASK`, `SNOWPARK_CONTAINER_SERVICES`, `AI_SERVICES`). \[3]
4. Resource monitors can suspend **user-managed warehouses** at thresholds, but they do **not** cover serverless features / AI services; Snowflake recommends using budgets for those. \[4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY | View | ACCOUNT_USAGE | Has `QUERY_TAG`, `WAREHOUSE_NAME`, `START_TIME/END_TIME`, `EXECUTION_TIME`, `CREDITS_USED_CLOUD_SERVICES` (not adjusted). \[1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly per-warehouse credits, plus `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to separate “query-execution credits” from idle. \[2] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY | View | ACCOUNT_USAGE | Hourly, per `SERVICE_TYPE` and entity; useful for non-warehouse services & serverless. \[3] |
| Resource Monitors | Object | User Guide | Works for warehouses only; can suspend user-managed warehouses when hitting credit quotas. \[4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Query-tag cost attribution (hourly):** Estimate credits by `QUERY_TAG` by distributing `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` across queries that ran in the same warehouse-hour.
2. **Idle-time cost (per warehouse):** Show idle credits = `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` per warehouse over a period (Snowflake provides an example query). \[2]
3. **“Non-warehouse spend” panel:** Break down `METERING_HISTORY` by `SERVICE_TYPE` to surface serverless / SPCS / AI service spend outside warehouse controls. \[3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: attribute hourly warehouse query credits to QUERY_TAG

**Goal:** Allocate `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution credits) across queries inside each *warehouse-hour* using a weight (default: `EXECUTION_TIME`).

Notes:
- This intentionally excludes idle time; idle can be reported separately using the warehouse metering view. \[2]
- This is an *allocation model* (not a perfect “billed-per-query” metric). Snowflake does not expose direct billed credits per query in these views.

```sql
-- COST ALLOCATION MODEL (warehouse-hour allocation)
-- Inputs: ACCOUNT_USAGE.QUERY_HISTORY + ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Output: estimated credits per QUERY_TAG per hour.

WITH params AS (
  SELECT
    DATEADD('day', -10, CURRENT_TIMESTAMP())::timestamp_ltz AS start_ts,
    CURRENT_TIMESTAMP()::timestamp_ltz                 AS end_ts
),

-- 1) Pull queries with timing + tag, bucketed to warehouse-hour
q AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                     AS hour_start,
    COALESCE(NULLIF(query_tag, ''), 'UNSPECIFIED')     AS query_tag,
    query_id,
    execution_time                                     AS execution_time_ms,
    total_elapsed_time                                 AS total_elapsed_time_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
    AND warehouse_name IS NOT NULL
    -- Optional: exclude non-success
    -- AND execution_status = 'SUCCESS'
),

-- 2) Compute weights within each warehouse-hour
q_weighted AS (
  SELECT
    warehouse_name,
    hour_start,
    query_tag,
    query_id,
    execution_time_ms,
    -- Weight choice: execution_time is usually better than total_elapsed_time
    -- because queuing/blocked time isn’t necessarily compute.
    GREATEST(execution_time_ms, 0)                     AS weight_ms
  FROM q
),

q_hour_totals AS (
  SELECT
    warehouse_name,
    hour_start,
    SUM(weight_ms) AS total_weight_ms
  FROM q_weighted
  GROUP BY 1,2
),

-- 3) Pull hourly credited usage for the same warehouse-hours
wmh AS (
  SELECT
    warehouse_name,
    start_time::timestamp_ltz                           AS hour_start,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
),

-- 4) Allocate hour’s query credits across queries (then aggregate by tag)
alloc AS (
  SELECT
    q.warehouse_name,
    q.hour_start,
    q.query_tag,
    q.query_id,
    wmh.credits_attributed_compute_queries,
    q.weight_ms,
    t.total_weight_ms,
    CASE
      WHEN t.total_weight_ms = 0 THEN 0
      ELSE (q.weight_ms / t.total_weight_ms) * wmh.credits_attributed_compute_queries
    END AS est_query_credits
  FROM q_weighted q
  JOIN q_hour_totals t
    ON q.warehouse_name = t.warehouse_name
   AND q.hour_start     = t.hour_start
  JOIN wmh
    ON q.warehouse_name = wmh.warehouse_name
   AND q.hour_start     = wmh.hour_start
)

SELECT
  hour_start,
  warehouse_name,
  query_tag,
  SUM(est_query_credits) AS est_credits_attributed_to_tag
FROM alloc
GROUP BY 1,2,3
ORDER BY hour_start DESC, est_credits_attributed_to_tag DESC;
```

### SQL draft: idle cost per warehouse (from Snowflake example)

```sql
SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_cost,
  warehouse_name
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('days', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocation model (credits attributed to queries are not exposed per-query) | Attribution may be “directionally correct” but not billing-grade per query | Compare aggregate allocated credits vs `credits_attributed_compute_queries` (should match by warehouse-hour); sanity-check against known workloads |
| Weight selection (`EXECUTION_TIME` vs `TOTAL_ELAPSED_TIME`, using `QUERY_LOAD_PERCENT`, etc.) | Can mis-allocate credits across tags | Run A/B weighting on sample periods; validate against operator intuition for workloads |
| View latency (ACCOUNT_USAGE) up to hours | “Near-real-time” dashboards may lag | Document freshness; optionally use alternative sources if needed (not researched in this note) |
| Resource monitors don’t cover serverless/AI spend | Users may expect monitor-like controls for all spend | Use budgets and show `METERING_HISTORY` service types to cover non-warehouse spend \[4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Confirm whether there is an official Snowflake-recommended method for per-query credit attribution (beyond hourly warehouse metering + heuristics).
- Add support for “UNSPECIFIED” tag detection and recommendations: enforce query tags via client configuration / session policy where possible.
- Expand model to include cloud services credits: query-level `CREDITS_USED_CLOUD_SERVICES` exists in `QUERY_HISTORY`, but billed adjustment nuances need care. \[1]
