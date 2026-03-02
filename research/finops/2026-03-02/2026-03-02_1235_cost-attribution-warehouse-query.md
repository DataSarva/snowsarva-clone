# Research: FinOps - 2026-03-02

**Time:** 1235 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-execution-only; excludes idle). It can have up to **180 minutes** latency (and up to **6 hours** for `CREDITS_USED_CLOUD_SERVICES`).
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` can be **greater than billed credits** because it does not apply the daily cloud services billing adjustment; Snowflake recommends using `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` to determine credits actually billed.
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` exposes **daily** billed credits and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative adjustment) and `CREDITS_BILLED` (compute + cloud services + adjustment). View latency may be up to **180 minutes**.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes per-query metadata like `QUERY_ID`, `QUERY_TEXT` (truncated at 100K chars), `WAREHOUSE_NAME`, `ROLE_NAME`, `USER_NAME`, and `QUERY_TAG`, plus execution metrics (e.g., `TOTAL_ELAPSED_TIME`, `BYTES_SCANNED`, queue times, etc.).
5. Snowflake “overall cost” is the sum of compute (credits), storage (TB-month), and data transfer (egress). Cloud services compute is billed **only when daily cloud services usage exceeds 10% of daily warehouse usage**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle); latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits, including `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query dimensions for attribution (warehouse/user/role/query_tag) + performance metrics. |
| Session `TIMEZONE` | Session setting | n/a | Snowflake notes: set `ALTER SESSION SET TIMEZONE = UTC` to reconcile with Organization Usage views. |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle cost leaderboard per warehouse** (hourly → daily rollup): compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` and surface top offenders.
2. **Query-tag cost attribution (estimated)**: join queries to warehouse-hours, allocate hourly `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` across queries (heuristic), and produce “top query_tags / roles / users by spend”.
3. **Billed vs consumed reconciliation**: compare `WAREHOUSE_METERING_HISTORY` (consumed) to `METERING_DAILY_HISTORY` (billed) and explicitly explain cloud services adjustment impact.

## Concrete Artifacts

### SQL draft: hourly warehouse spend + idle credits

```sql
-- Hourly warehouse credit usage + idle (compute) credits.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   * credits_used includes cloud services and may exceed billed credits
--   * idle is compute-only and derived from compute fields

ALTER SESSION SET TIMEZONE = UTC;

WITH wh AS (
  SELECT
    start_time,
    end_time,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS idle_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= dateadd('day', -30, current_timestamp())
)
SELECT
  date_trunc('day', start_time) AS usage_day,
  warehouse_name,
  sum(credits_used_compute)              AS compute_credits,
  sum(credits_used_cloud_services)       AS cloud_services_credits_consumed,
  sum(credits_used)                      AS total_credits_consumed,
  sum(credits_attributed_compute_queries) AS query_compute_credits_attributed,
  sum(idle_compute_credits)              AS idle_compute_credits
FROM wh
GROUP BY 1, 2
ORDER BY usage_day DESC, total_credits_consumed DESC;
```

### SQL draft: estimated per-query attribution (hourly allocation heuristic)

```sql
-- Goal: estimate per-query credit attribution without a first-class “credits per query” metric.
-- Heuristic:
--   1) For each warehouse-hour, take WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES
--   2) Allocate across queries in that warehouse-hour proportional to (execution_time_ms)
-- Caveats:
--   * This is an approximation; it ignores concurrency details and uses query execution time as a proxy.
--   * Idle time is explicitly excluded by using credits_attributed_compute_queries.

ALTER SESSION SET TIMEZONE = UTC;

WITH wh_hour AS (
  SELECT
    warehouse_name,
    start_time,
    end_time,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
),
q AS (
  SELECT
    query_id,
    warehouse_name,
    query_tag,
    user_name,
    role_name,
    start_time,
    end_time,
    execution_time AS execution_time_ms
  FROM snowflake.account_usage.query_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
    AND warehouse_name IS NOT NULL
    AND execution_status = 'SUCCESS'
),
q_in_hour AS (
  SELECT
    w.warehouse_name,
    w.start_time AS hour_start,
    w.end_time   AS hour_end,
    w.credits_attributed_compute_queries,
    q.query_id,
    q.query_tag,
    q.user_name,
    q.role_name,
    q.execution_time_ms
  FROM wh_hour w
  JOIN q
    ON q.warehouse_name = w.warehouse_name
   -- Include queries that overlap the hour window
   AND q.start_time < w.end_time
   AND coalesce(q.end_time, q.start_time) >= w.start_time
),
alloc AS (
  SELECT
    *,
    sum(execution_time_ms) OVER (
      PARTITION BY warehouse_name, hour_start
    ) AS hour_total_execution_ms
  FROM q_in_hour
)
SELECT
  warehouse_name,
  hour_start,
  query_id,
  query_tag,
  user_name,
  role_name,
  execution_time_ms,
  credits_attributed_compute_queries,
  iff(hour_total_execution_ms = 0, 0,
      credits_attributed_compute_queries * (execution_time_ms / hour_total_execution_ms)
  ) AS estimated_query_credits
FROM alloc
ORDER BY hour_start DESC, estimated_query_credits DESC;
```

### Proposed table schema: `MC_FINOPS.ATTRIBUTION_QUERY_HOURLY` (materialized output)

```sql
CREATE TABLE IF NOT EXISTS mc_finops.attribution_query_hourly (
  usage_hour         TIMESTAMP_LTZ NOT NULL,
  warehouse_name     STRING        NOT NULL,
  query_id           STRING        NOT NULL,
  query_tag          STRING,
  user_name          STRING,
  role_name          STRING,
  execution_time_ms  NUMBER,
  estimated_query_credits NUMBER(38, 12),
  source_hour_attributed_credits NUMBER(38, 12),
  allocation_method  STRING        NOT NULL, -- e.g. 'EXECUTION_TIME_PROPORTIONAL_V1'
  created_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hourly-to-query allocation is heuristic (execution time ≠ credits). | Misstated per-query / per-tag costs; could mislead optimization priorities. | Compare aggregates: sum(estimated_query_credits) per hour should match `credits_attributed_compute_queries`; sanity-check against known workloads / benchmarks. |
| `ACCOUNT_USAGE` view latency (3–6h) can cause “missing” recent hours. | Near-real-time dashboards appear incomplete. | Add “data freshness” banners; only report through `dateadd('hour', -6, current_timestamp())`. |
| `CREDITS_USED` ≠ `CREDITS_BILLED` due to cloud services adjustment logic. | Confusion in reconciliation vs invoice. | Provide explicit “consumed vs billed” reconciliation view and documentation. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/user-guide/cost-understanding-overall

## Next Steps / Follow-ups

- Extend attribution beyond warehouses: identify additional `METERING_DAILY_HISTORY.SERVICE_TYPE` buckets relevant to FinOps (e.g., SEARCH_OPTIMIZATION, SNOWPIPE_STREAMING, SNOWPARK_CONTAINER_SERVICES) and decide which ones are in MVP.
- Add a “reconciliation mode” report: daily consumed (warehouse hourly rollup) vs daily billed (`METERING_DAILY_HISTORY`) with explanation of cloud services adjustment.
- Decide product UX: do we treat query-level credit attribution as **explicitly “estimated”** until Snowflake provides a first-class metric?
