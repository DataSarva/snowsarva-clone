# Research: FinOps - 2026-02-27

**Time:** 07:33 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s `SNOWFLAKE.ACCOUNT_USAGE` schema provides account-level metadata and historical usage metrics (e.g., credits, storage, transfer) with non-zero data latency (typically ~45 minutes to ~3 hours depending on the view) and up to 1 year retention for historical usage views.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage
2. The Information Schema table function `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` returns hourly credit usage for a warehouse (or all warehouses) for a specified date range, but is limited to the last 6 months; for longer/complete retention, Snowflake recommends using the `ACCOUNT_USAGE` view instead.  
   Source: https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
3. When reconciling account-level cost views (e.g., `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`) against organization-level usage (ORG_USAGE), Snowflake documentation calls out that you must set the session timezone to UTC to reconcile correctly.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage
4. A practical “per-query cost monitoring” pattern is to combine `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` with `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` by time-window containment (query start/end inside metering interval) to approximate `credits_used` attribution to individual queries.  
   Source: https://www.snowflake.com/en/developers/guides/query-cost-monitoring/
5. `ACCOUNT_USAGE` access can/should be granted via SNOWFLAKE database roles (e.g., `USAGE_VIEWER`, `GOVERNANCE_VIEWER`) rather than broad `IMPORTED PRIVILEGES` to reduce accidental visibility into organization-level data.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by warehouse; historical (1 year) with ~3h latency. (Latency varies by view.) |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | INFO_SCHEMA | Only last 6 months; use `ACCOUNT_USAGE` for complete historical dataset. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Per-query metadata/metrics; historical with ~45m latency; includes warehouse, user, role, times, etc. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Metering intervals with `credits_used`; commonly joined to `QUERY_HISTORY` by time containment for per-query attribution. |
| `SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE` | View | ACCOUNT_USAGE | Storage bytes (tables/stages/failsafe); typically ~2h latency; useful for storage cost trendlines. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost attribution spine” table**: a scheduled job that builds a daily fact table with credits by warehouse + (optional) approximate credits by query/user/role using `ACCOUNT_USAGE` joins; drives the Native App’s dashboards.
2. **Data latency + reconciliation warnings**: in-product UX callouts that annotate charts with the underlying view latency (45m–3h) and enforce `ALTER SESSION SET TIMEZONE = UTC` in app-owned worksheets when showing reconciled org/account totals.
3. **Least-privilege data access blueprint**: ship a setup checker that validates the consumer has the minimum SNOWFLAKE database roles (e.g., `USAGE_VIEWER`) required for cost reporting instead of requiring `IMPORTED PRIVILEGES`.

## Concrete Artifacts

### SQL Draft: Daily warehouse credits + approximate per-query attribution

This is a *first-pass* pattern you can embed in a Native App “cost model” schema. It intentionally:
- normalizes to UTC for reconciliation scenarios
- aggregates warehouse credits from `WAREHOUSE_METERING_HISTORY`
- approximates per-query credit attribution by joining queries to metering windows (containment)

```sql
-- COST ATTRIBUTION SPINE (DRAFT)
-- Sources:
-- - ACCOUNT_USAGE overview + timezone reconciliation guidance:
--   https://docs.snowflake.com/en/sql-reference/account-usage
-- - Per-query attribution pattern (query_history + metering_history):
--   https://www.snowflake.com/en/developers/guides/query-cost-monitoring/

-- 0) (Optional but recommended when reconciling against ORG_USAGE)
ALTER SESSION SET TIMEZONE = UTC;

-- Parameters (replace with bindings in Snowpark / tasks)
SET DAYS_BACK = 30;

-- 1) Daily warehouse credits (authoritative at warehouse-hour granularity)
WITH wh_daily AS (
  SELECT
    start_time::date                AS usage_date,
    warehouse_name,
    SUM(credits_used)              AS credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -$DAYS_BACK, CURRENT_TIMESTAMP())
  GROUP BY 1,2
),

-- 2) Approx per-query credits using metering window containment
-- NOTE: This is an approximation because metering is at interval level.
query_cost AS (
  SELECT
    q.query_id,
    q.start_time::date              AS usage_date,
    q.user_name,
    q.role_name,
    q.database_name,
    q.schema_name,
    q.warehouse_name,
    q.warehouse_size,
    m.credits_used                  AS credits_used_interval,
    q.execution_time/1000           AS execution_time_s,
    q.total_elapsed_time/1000       AS total_elapsed_time_s
  FROM snowflake.account_usage.query_history q
  JOIN snowflake.account_usage.metering_history m
    ON q.start_time >= m.start_time
   AND q.end_time   <= m.end_time
  WHERE q.start_time >= DATEADD('day', -$DAYS_BACK, CURRENT_TIMESTAMP())
    AND q.execution_status = 'SUCCESS'
),

-- 3) Reduce double-counting by distributing interval credits proportionally by query execution time
-- within (warehouse_name, metering interval). This is still approximate.
interval_weights AS (
  SELECT
    m.start_time,
    m.end_time,
    q.warehouse_name,
    q.query_id,
    q.usage_date,
    q.user_name,
    q.role_name,
    q.database_name,
    q.schema_name,
    q.warehouse_size,
    q.execution_time_s,
    -- total exec time in the interval for weighting
    SUM(q.execution_time_s) OVER (
      PARTITION BY q.warehouse_name, m.start_time, m.end_time
    ) AS interval_total_exec_s,
    m.credits_used AS interval_credits
  FROM snowflake.account_usage.query_history q
  JOIN snowflake.account_usage.metering_history m
    ON q.start_time >= m.start_time
   AND q.end_time   <= m.end_time
  WHERE q.start_time >= DATEADD('day', -$DAYS_BACK, CURRENT_TIMESTAMP())
    AND q.execution_status = 'SUCCESS'
),

query_credits_weighted AS (
  SELECT
    usage_date,
    warehouse_name,
    query_id,
    user_name,
    role_name,
    database_name,
    schema_name,
    warehouse_size,
    execution_time_s,
    interval_credits,
    interval_total_exec_s,
    IFF(interval_total_exec_s > 0,
        interval_credits * (execution_time_s / interval_total_exec_s),
        NULL
    ) AS credits_attributed
  FROM interval_weights
)

SELECT
  usage_date,
  warehouse_name,
  SUM(credits_attributed) AS credits_attributed_to_queries
FROM query_credits_weighted
GROUP BY 1,2
ORDER BY 1 DESC, 2;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Per-query credit attribution from `METERING_HISTORY` interval containment is approximate (metering is interval-based, queries overlap, and windows may not map 1:1). | Misleading “exact” cost per query if presented without caveats. | Compare weighted attribution totals vs `WAREHOUSE_METERING_HISTORY` totals; present as “estimated” in UI. (See Streamlit quickstart join pattern.) https://www.snowflake.com/en/developers/guides/query-cost-monitoring/ |
| `ACCOUNT_USAGE` has latency (45m–3h depending on view). | Dashboards can look “behind” real time and trigger false alarms. | Surface latency in UI; document freshness SLA; confirm per-view latency from docs. https://docs.snowflake.com/en/sql-reference/account-usage |
| UTC session timezone requirement for reconciliation vs ORG_USAGE. | Mismatched daily totals if consumer runs in non-UTC timezone. | Enforce `ALTER SESSION SET TIMEZONE = UTC` in app-managed queries when reconciling. https://docs.snowflake.com/en/sql-reference/account-usage |
| Access model: broad `IMPORTED PRIVILEGES` is easy but may overexpose. | Governance/security risk for an admin-facing FinOps app. | Prefer database roles (`USAGE_VIEWER`, etc.) for least privilege. https://docs.snowflake.com/en/sql-reference/account-usage |

## Links & Citations

1. Snowflake Docs — Account Usage overview, latency/retention, roles, and reconciliation note: https://docs.snowflake.com/en/sql-reference/account-usage
2. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` table function (6-month limit; use ACCOUNT_USAGE for complete history): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
3. Snowflake Developer Guide — Query cost monitoring tool (join `query_history` to `metering_history`): https://www.snowflake.com/en/developers/guides/query-cost-monitoring/
4. Snowflake Developer Guide — Cost/perf optimization and example `ACCOUNT_USAGE` queries (warehouse metering, storage usage, access history): https://www.snowflake.com/en/developers/guides/getting-started-cost-performance-optimization/

## Next Steps / Follow-ups

- Decide how the Native App should present “estimated per-query credits” vs “authoritative per-warehouse credits” (UX + data model).
- Add a small ADR for cost attribution methodology (interval containment vs weighted by execution time vs other heuristics).
- Extend the spine to storage: `ACCOUNT_USAGE.STORAGE_USAGE` trendlines + churn detection (tables with high non-active bytes).
