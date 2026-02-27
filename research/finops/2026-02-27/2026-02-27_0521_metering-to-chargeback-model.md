# Research: FinOps - 2026-02-27

**Time:** 05:21 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including total credits used as a sum of compute + cloud services and a separate metric for credits attributed to compute queries (excluding idle). It also documents view latency (up to 180 minutes, and cloud services up to 6 hours). 
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` returns **hourly** credit usage at the account level (last **365 days**) broken down by `SERVICE_TYPE` (warehouse metering, serverless/task, AI services, etc.), with separate compute vs cloud services credits and naming/ID fields that vary by service type. 
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes fields needed for basic cost attribution dimensions (user/role/warehouse, start/end time, query_tag, bytes scanned/spilled, execution/queued times, and `credits_used_cloud_services`), enabling “who/what/when” slicing of compute usage even if the warehouse-level billing rollups come from metering views.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history

4. Resource Monitors can **control** costs by monitoring credit usage for **warehouses only** and can notify and/or suspend user-managed warehouses at thresholds; Snowflake explicitly notes they **do not** cover serverless/AI services and suggests using **Budgets** for those.
   - Source: https://docs.snowflake.com/en/user-guide/resource-monitors

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits per warehouse. Includes `CREDITS_USED_*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 180 min; cloud services up to 6h. |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits by service type across the account; useful to capture non-warehouse costs (serverless, AI services, etc.) via `SERVICE_TYPE`. |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY | View | ACCOUNT_USAGE | Per-query attributes: `QUERY_TAG`, `WAREHOUSE_NAME`, `ROLE_NAME`, timings, bytes, and per-query `credits_used_cloud_services` (not necessarily billed). |
| RESOURCE MONITOR (object) | Object | N/A (DDL object) | Only applies to warehouses; can notify/suspend; resets at 12:00 AM UTC per schedule. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost detector (warehouse-level)**: Daily report of idle credits per warehouse using `credits_used_compute - credits_attributed_compute_queries` from `WAREHOUSE_METERING_HISTORY`, with a “top offenders” view.

2. **Cost attribution starter pack (tag/role/user)**: Aggregate `QUERY_HISTORY` by `QUERY_TAG`, `ROLE_NAME`, `USER_NAME`, `WAREHOUSE_NAME` to produce cost/efficiency dashboards (e.g., cost vs bytes scanned, queued time, spill).

3. **Non-warehouse spend radar**: Track `METERING_HISTORY` by `SERVICE_TYPE` to surface “surprise spend” classes (e.g., serverless tasks, search optimization, AI services) that resource monitors won’t catch.

## Concrete Artifacts

### Artifact: Daily warehouse cost + idle credits model (SQL draft)

Goal: Build a durable daily facts table to power a Native App UI/API (chargeback, anomaly detection, recommendations).

```sql
-- Assumptions:
-- - You have a database/schema for app-owned tables (example: FINOPS_DB.FINOPS).
-- - You want UTC alignment for reconciliation (Snowflake notes timezone considerations).

ALTER SESSION SET TIMEZONE = 'UTC';

CREATE SCHEMA IF NOT EXISTS FINOPS_DB.FINOPS;

CREATE OR REPLACE TABLE FINOPS_DB.FINOPS.FACT_WAREHOUSE_CREDITS_DAILY AS
WITH hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time)                       AS usage_date,
    warehouse_name,
    SUM(credits_used)                                  AS credits_used_total,
    SUM(credits_used_compute)                           AS credits_used_compute,
    SUM(credits_used_cloud_services)                    AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries)             AS credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
final AS (
  SELECT
    usage_date,
    warehouse_name,
    credits_used_total,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    GREATEST(credits_used_compute - credits_attributed_compute_queries, 0) AS credits_idle_compute
  FROM hourly
)
SELECT * FROM final;

-- Optional: slice query behavior by tag/role/user for the same window.
-- This does *not* directly yield compute credits (warehouse compute billing is warehouse-level),
-- but it provides dimensions to attribute / allocate in a second-stage model.
CREATE OR REPLACE VIEW FINOPS_DB.FINOPS.V_QUERY_DAILY_DIMENSIONS AS
SELECT
  DATE_TRUNC('DAY', start_time) AS query_date,
  warehouse_name,
  role_name,
  user_name,
  COALESCE(query_tag, '<NULL>') AS query_tag,
  COUNT(*)                      AS query_count,
  SUM(bytes_scanned)            AS bytes_scanned,
  SUM(execution_time)           AS execution_time_ms,
  SUM(queued_overload_time)     AS queued_overload_time_ms,
  SUM(bytes_spilled_to_remote_storage) AS bytes_spilled_remote
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
GROUP BY 1,2,3,4,5;
```

**Why this artifact matters:** it bootstraps a common FinOps pattern: (a) authoritative spend rollups from metering views, (b) behavioral attribution dimensions from query history, and (c) explicit separation of “idle compute” to drive optimization recommendations.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ACCOUNT_USAGE latency (up to hours) means “today” may be incomplete | Near-real-time dashboards may mislead | Confirm freshness by checking max(END_TIME) / documented latency; consider incremental loads with a trailing window | 
| `credits_used_*` values may not equal billed credits due to cloud services adjustments | Chargeback model might not reconcile to invoice | Use `METERING_DAILY_HISTORY` for billed reconciliation when needed (not fetched in this session); document which metric powers which report | 
| Query-level attribution of warehouse compute is not directly provided | Any per-tag/user “compute dollars” will involve allocation logic | Implement allocation rules explicitly (proportional to execution_time, bytes scanned, etc.) and validate with stakeholders | 
| Resource monitors only cover warehouses | False sense of safety for serverless/AI spend | Use `METERING_HISTORY` `SERVICE_TYPE` monitoring + Budgets for non-warehouse spend categories | 

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Pull and cite `METERING_DAILY_HISTORY` docs next session to pin down “billed credits” reconciliation mechanics (vs raw usage credits).
- Define an allocation ADR for mapping warehouse compute credits onto query tags/teams (choose 1 default and allow configurable policies).
- Add an anomaly detector candidate: daily z-score / STL on `credits_used_total` by warehouse + `SERVICE_TYPE`.
