# Research: FinOps - 2026-03-02

**Time:** 16:50 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s *compute* cost includes credits consumed by virtual warehouses, serverless features, and the cloud services layer; however, cloud services credits are **billed only when daily cloud services consumption exceeds 10% of daily warehouse usage**, and many dashboards/views show consumed credits without that daily billing adjustment. To determine what was actually billed, query `METERING_DAILY_HISTORY`. 
   - Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` exposes query history over the **last 365 days**, including performance breakdown columns (e.g., `COMPILATION_TIME`, `EXECUTION_TIME`, queue times) and `CREDITS_USED_CLOUD_SERVICES` (not billing-adjusted). Latency for Account Usage views can be **up to 45 minutes**.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. The Information Schema table function `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` returns hourly credit usage for a warehouse (or all warehouses) for a specified date range, but is limited to the **last 6 months**, and can be incomplete for long date ranges across many warehouses; for completeness, Snowflake recommends using the `ACCOUNT_USAGE` view.
   - Source: https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
4. Snowflake’s developer guide for query cost monitoring demonstrates a practical approach: join `ACCOUNT_USAGE.QUERY_HISTORY` to `ACCOUNT_USAGE.METERING_HISTORY` by time window to approximate per-query credit usage (query start/end within metering window).
   - Source: https://www.snowflake.com/en/developers/guides/query-cost-monitoring/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | 365d history; latency up to ~45 min; includes queue time + cloud services credits (consumed, may not equal billed). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Use to reconcile actual billed cloud services via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (see Exploring compute cost doc). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly metering for warehouses/serverless/etc. Useful for time-bucket joins. (Mentioned in Snowflake guide.) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly per-warehouse credits incl. cloud services portion (consumed). Referenced by cost exploration doc. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFORMATION_SCHEMA` | Last 6 months; may be incomplete over long ranges; requires `MONITOR USAGE` global privilege. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost driver explainer” for expensive queries**: rank queries by *approx credits* (via hourly time-bucket join) and attach performance breakdown signals (queue/compile/exec/list-external-files) from `QUERY_HISTORY` to explain *why* they are expensive.
2. **Cloud services overage detector (billed vs consumed)**: daily job that reads `METERING_DAILY_HISTORY` and flags days where cloud services were billed (i.e., net billed cloud services > 0) and correlates to query patterns (`QUERY_TYPE`, `LIST_EXTERNAL_FILES_TIME`, etc.).
3. **Warehouse waste pattern cards**: per-warehouse hourly credit burn from `WAREHOUSE_METERING_HISTORY` with overlays for overload queue time spikes from `QUERY_HISTORY` to suggest resizing vs concurrency fixes.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Per-query “approx credits” attribution (time-bucket join)

Goal: produce a query-level table suitable for an in-app “top costly queries” view, using only broadly-available `ACCOUNT_USAGE` views.

```sql
-- APPROXIMATE per-query credits by distributing warehouse-hour credits
-- proportionally to query execution_time within that (warehouse, hour) bucket.
--
-- Sources:
-- - QUERY_HISTORY columns + 365d retention: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
-- - Warehouse hourly credits patterns: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
--
-- Assumptions / limitations:
-- - This is an approximation; it allocates warehouse-hour credits to queries.
-- - It ignores idle time unless you explicitly redistribute idle.
-- - ACCOUNT_USAGE view latency up to ~45 minutes.

WITH q AS (
  SELECT
    query_id,
    query_text,
    query_hash,
    query_parameterized_hash,
    user_name,
    role_name,
    warehouse_name,
    query_type,
    query_tag,
    start_time,
    end_time,
    execution_status,
    compilation_time,
    execution_time,
    queued_overload_time,
    queued_provisioning_time,
    list_external_files_time,
    credits_used_cloud_services
  FROM snowflake.account_usage.query_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
    AND warehouse_name IS NOT NULL
    AND execution_time IS NOT NULL
    AND execution_time > 0
),
q_hour AS (
  SELECT
    date_trunc('hour', start_time) AS hour_start,
    warehouse_name,
    query_id,
    execution_time
  FROM q
),
warehouse_hour AS (
  SELECT
    start_time AS hour_start,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
    AND warehouse_id > 0  -- skip pseudo VWs like CLOUD_SERVICES_ONLY
),
execution_totals AS (
  SELECT
    hour_start,
    warehouse_name,
    sum(execution_time) AS total_execution_time_ms
  FROM q_hour
  GROUP BY 1,2
),
alloc AS (
  SELECT
    qh.hour_start,
    qh.warehouse_name,
    qh.query_id,
    wh.credits_used_compute,
    wh.credits_used_cloud_services AS wh_credits_cloud_services,
    wh.credits_used AS wh_credits_total,
    et.total_execution_time_ms,
    qh.execution_time,
    -- proportional allocation
    (qh.execution_time / nullif(et.total_execution_time_ms, 0)) * wh.credits_used_compute AS approx_credits_used_compute,
    (qh.execution_time / nullif(et.total_execution_time_ms, 0)) * wh.credits_used AS approx_credits_used_total
  FROM q_hour qh
  JOIN execution_totals et
    ON et.hour_start = qh.hour_start AND et.warehouse_name = qh.warehouse_name
  JOIN warehouse_hour wh
    ON wh.hour_start = qh.hour_start AND wh.warehouse_name = qh.warehouse_name
)
SELECT
  q.query_id,
  q.query_hash,
  q.query_parameterized_hash,
  q.user_name,
  q.role_name,
  q.warehouse_name,
  q.query_type,
  q.query_tag,
  q.start_time,
  q.end_time,
  q.execution_status,
  q.compilation_time,
  q.execution_time,
  q.queued_overload_time,
  q.queued_provisioning_time,
  q.list_external_files_time,
  q.credits_used_cloud_services,
  sum(a.approx_credits_used_compute) AS approx_credits_used_compute,
  sum(a.approx_credits_used_total) AS approx_credits_used_total
FROM q
JOIN alloc a
  ON a.query_id = q.query_id
GROUP BY ALL
ORDER BY approx_credits_used_total DESC
LIMIT 200;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Cloud services `CREDITS_USED_CLOUD_SERVICES` in `QUERY_HISTORY` reflects consumption and may not match billed credits due to daily adjustment | Incorrect $ attribution if you treat consumed as billed | Use `METERING_DAILY_HISTORY` to compute billed cloud services (per Snowflake cost doc) | 
| Time-bucket allocation assumes credits scale with summed query `EXECUTION_TIME` within a warehouse-hour | Can misattribute cost when concurrency/queuing/idle dominates | Compare approximation vs `QUERY_ATTRIBUTION_HISTORY` (not extracted here) when available; sanity-check totals vs `WAREHOUSE_METERING_HISTORY` | 
| ACCOUNT_USAGE view latency up to ~45 minutes | Near-real-time dashboards may lag | Document lag + optionally use Information Schema functions for short windows | 
| Information Schema `WAREHOUSE_METERING_HISTORY` table function is limited to last 6 months and can be incomplete for large queries | Incomplete datasets for long-range reporting | Prefer `ACCOUNT_USAGE` views for completeness (per Snowflake docs) | 

## Links & Citations

1. Exploring compute cost (cloud services billing adjustment; core cost views): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. QUERY_HISTORY view reference (365d retention; performance columns; latency note): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. WAREHOUSE_METERING_HISTORY table function (6 month limit; privileges; output columns): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
4. Query cost monitoring guide (joins query history to metering history): https://www.snowflake.com/en/developers/guides/query-cost-monitoring/

## Next Steps / Follow-ups

- Pull and cite `QUERY_ATTRIBUTION_HISTORY` docs (and/or `QUERY_ACCELERATION_*` views) to replace approximation with first-party per-query credits where possible.
- Decide product stance: keep both “approx allocation” (works broadly) and “authoritative attribution” (when view available) with explainability notes.
- Add a cost normalization layer: currency conversion via `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` when org-level access is available.
