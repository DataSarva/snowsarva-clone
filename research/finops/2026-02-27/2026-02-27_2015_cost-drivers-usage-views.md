# Research: FinOps - 2026-02-27

**Time:** 20:15 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly credit usage by service type** (not just warehouses) for the last **365 days**, including both compute and cloud services credits; it includes identifiers such as `ENTITY_ID`, `ENTITY_TYPE`, and optional `DATABASE_NAME/SCHEMA_NAME` where applicable. It has latency up to ~3 hours (cloud services up to ~6 hours; Snowpipe Streaming up to ~12 hours).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credit usage per warehouse** for the last **365 days** and includes a column `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributed to query execution only) that excludes idle time; idle credits can be estimated as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

3. When reconciling ACCOUNT_USAGE metering views with ORGANIZATION_USAGE equivalents, Snowflake docs explicitly call out setting the session timezone to **UTC** before querying ACCOUNT_USAGE to avoid mismatch.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

4. Resource monitors can **monitor and (optionally) suspend** user-managed warehouses when credit thresholds are reached, but they **only apply to warehouses**. They cannot track serverless features/AI services; Snowflake recommends using a **budget** for those. Also, monitor thresholds do **not** consider the “daily 10% adjustment for cloud services.”  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors

5. Snowflake’s Resource Optimization “Usage Monitoring” quickstart includes reference SQL for tiered monitoring, including **credit consumption by warehouse**, **hourly consumption patterns**, **cloud-services-heavy warehouses**, and **approximate credit attribution** by user or client application by proportionally allocating hourly warehouse credits using `QUERY_HISTORY.EXECUTION_TIME` within the same hour/warehouse.  
   Source: https://www.snowflake.com/en/developers/guides/resource-optimization-usage-monitoring/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by `SERVICE_TYPE` across account; includes `CREDITS_USED_*` and sometimes `DATABASE/SCHEMA` metadata depending on service type. Latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Used for workload dimensions + potential approximate chargeback methods (by execution time, warehouse, hour). Latency ~45 min per docs for this view (see its reference page; not extracted in this session). |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Cross-account org-level warehouse metering; reconcile requires UTC session on AU side. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost “service-type ledger” dataset**: Build a daily/hourly fact table from `ACCOUNT_USAGE.METERING_HISTORY` keyed by `service_type`, `entity_type`, `name`, and optional `{database,schema}` to show where non-warehouse spend is going (serverless tasks, auto-clustering, materialized views, Snowpipe streaming, etc.).

2. **Warehouse efficiency panel**: Use `WAREHOUSE_METERING_HISTORY` + `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to compute idle credits per warehouse/day (and trend it). This becomes a high-signal “waste” metric that’s less controversial than per-query chargeback.

3. **Approximate chargeback module (explicitly labeled)**: Add an opt-in “approximate attribution” model for user/client app using the quickstart’s execution-time proportional allocation (warehouse credits per hour × user execution_time share in that hour). Ship with strong disclaimers and validation checks.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: “Daily Cost Ledger” (service-type + warehouse + idle)

Goal: produce a single daily rollup table that:
- separates spend by `SERVICE_TYPE` (warehouse vs serverless/other),
- breaks warehouse spend into **compute vs cloud services**,
- adds **idle credits** per warehouse/day.

```sql
-- DAILY COST LEDGER (DRAFT)
-- Notes:
-- 1) ACCOUNT_USAGE timestamps are in local time zone; for reconciliation with ORG_USAGE, Snowflake recommends UTC.
-- 2) ACCOUNT_USAGE views have latency (hours). Use a watermark lag in scheduled pipelines.

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Daily service-type credits (non-warehouse + warehouse aggregate)
WITH metering_daily AS (
  SELECT
      TO_DATE(start_time)                                  AS usage_date,
      service_type,
      entity_type,
      name,
      database_name,
      schema_name,
      SUM(credits_used_compute)                            AS credits_used_compute,
      SUM(credits_used_cloud_services)                     AS credits_used_cloud_services,
      SUM(credits_used)                                    AS credits_used
  FROM snowflake.account_usage.metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3,4,5,6
),

-- 2) Daily warehouse credits + idle credits (warehouse-level)
warehouse_daily AS (
  SELECT
      TO_DATE(start_time)                                  AS usage_date,
      warehouse_id,
      warehouse_name,
      SUM(credits_used_compute)                            AS wh_credits_used_compute,
      SUM(credits_used_cloud_services)                     AS wh_credits_used_cloud_services,
      SUM(credits_used)                                    AS wh_credits_used,
      SUM(credits_attributed_compute_queries)              AS wh_credits_attributed_compute_queries,
      ( SUM(credits_used_compute)
        - SUM(credits_attributed_compute_queries) )        AS wh_idle_credits_est
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
)

-- Example: materialize to your app schema
SELECT
  m.usage_date,
  m.service_type,
  m.entity_type,
  m.name,
  m.database_name,
  m.schema_name,
  m.credits_used_compute,
  m.credits_used_cloud_services,
  m.credits_used,
  -- optionally enrich with warehouse rollups when service_type = 'WAREHOUSE_METERING'
  w.wh_credits_used_compute,
  w.wh_credits_used_cloud_services,
  w.wh_credits_used,
  w.wh_idle_credits_est
FROM metering_daily m
LEFT JOIN warehouse_daily w
  ON m.usage_date = w.usage_date
 AND m.service_type = 'WAREHOUSE_METERING'
 AND m.entity_type  = 'WAREHOUSE'
 AND m.name          = w.warehouse_name;
```

Why this matters for the Native App:
- `METERING_HISTORY` is the cleanest “top-level truth” for **where credits are going** (by service type).
- `WAREHOUSE_METERING_HISTORY` is required for warehouse-specific operational levers (idle/waste, autosuspend, right-sizing).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` has non-trivial latency; reports can look “wrong” for most recent hours/day. | False alerts; churn. | Use a time watermark (e.g., only compute “final” metrics up to `CURRENT_TIMESTAMP() - INTERVAL '6 HOURS'`). Docs list up to 6h for cloud services columns. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history ; https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |
| Warehouse “idle” is estimated from metering minus attributed query credits; this is not a per-query truth. | Might be misinterpreted as “bad.” | Label clearly as “idle credits estimate” and show it alongside total credits and query-attributed credits. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |
| Approximate user/client-app attribution uses proportional allocation by execution time; it’s a model, not billing truth. | Potentially contentious chargeback. | Keep it opt-in, explain assumptions, and allow multiple allocation strategies. Quickstart provides the base method. https://www.snowflake.com/en/developers/guides/resource-optimization-usage-monitoring/ |
| Resource monitors cannot cover serverless/AI services. | Users may think monitors “cap spend” globally; they don’t. | Surface this limitation in UI and recommend budgets for non-warehouse services. https://docs.snowflake.com/en/user-guide/resource-monitors |

## Links & Citations

1. METERING_HISTORY (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
2. WAREHOUSE_METERING_HISTORY (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Resource Monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
4. Resource Optimization Quickstart (Usage Monitoring): https://www.snowflake.com/en/developers/guides/resource-optimization-usage-monitoring/

## Next Steps / Follow-ups

- Extend this to **ORG_USAGE**: map `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` + `USAGE_IN_CURRENCY_DAILY` for multi-account org reporting and reconciliation rules (UTC handling, latency).
- Identify the top handful of `SERVICE_TYPE` values that matter for FinOps MVP (e.g., `WAREHOUSE_METERING`, `SERVERLESS_TASK`, `AUTO_CLUSTERING`, `MATERIALIZED_VIEW`, `SNOWPIPE_STREAMING`, `AI_SERVICES`) and build a stable dimension table for them.
- Draft UI: “Where credits went” (service-type stacked area) + “Waste” (idle credits) + “Levers” (autosuspend, warehouse settings, task schedule).
