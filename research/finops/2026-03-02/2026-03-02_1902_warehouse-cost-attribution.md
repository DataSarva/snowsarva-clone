# Research: FinOps - 2026-03-02

**Time:** 1902 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake exposes hourly warehouse credit usage (including associated cloud services cost) via the `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view, and also via an Information Schema table function `WAREHOUSE_METERING_HISTORY()` (the table function is limited to the last 6 months and may be incomplete for long ranges across multiple warehouses; Snowflake recommends using the `ACCOUNT_USAGE` view for a complete data set).  
   Source: https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

2. Snowflake compute “credit usage” views commonly represent **consumed** credits and may not directly reflect what is **billed** for cloud services; cloud services are billed only if daily cloud services consumption exceeds 10% of daily virtual warehouse usage, and Snowflake recommends querying `METERING_DAILY_HISTORY` to determine billed compute credits.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

3. Resource monitors are cost-control objects that can notify and/or suspend user-managed warehouses when credit usage reaches configured thresholds; account-level resource monitors do not control serverless feature credit usage (e.g., Snowpipe, Automatic Clustering), and warehouse-level monitors can monitor but cannot suspend cloud services credit usage.  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors

4. Budgets define a monthly spending limit (in credits) for an account or a group of objects; notifications can be sent to emails and several webhook / cloud-queue destinations, and budgets can be configured to invoke stored procedures as user-defined actions. Budgets have a refresh interval (default up to ~6.5 hours; “low latency” 1 hour) and lowering the interval increases the compute cost of the budget itself.  
   Source: https://docs.snowflake.com/en/user-guide/budgets

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY()` | Table function | INFO_SCHEMA | Hourly warehouse credits for a date range; returns last 6 months; Snowflake warns it may be incomplete for long ranges / multiple warehouses and suggests `ACCOUNT_USAGE` for completeness. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by warehouse, includes cloud services associated with warehouse usage. (Use `warehouse_id > 0` to exclude pseudo warehouses like `CLOUD_SERVICES_ONLY` in some example queries.) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits by service type; used to determine whether cloud services were actually billed (vs consumed). |
| `SNOWFLAKE.ACCOUNT_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ACCOUNT_USAGE | Converts credits consumed into currency cost using the daily price of a credit (good for “$” dashboards). |
| `CREATE RESOURCE MONITOR` / `ALTER RESOURCE MONITOR` | DDL | N/A | Enforcement controls for warehouses (notify/suspend), but not full coverage of serverless costs. |
| Budget class / Budgets UI | Feature | N/A | Monthly windows are UTC; refresh-tier tradeoff (latency vs budget compute cost). |

## MVP Features Unlocked

1. **“Warehouse spend drilldown” API layer**: ship a standard set of app queries that return (a) hourly warehouse credits, (b) cloud-services ratio by warehouse, (c) daily billed cloud-services deltas, and expose it via the Native App UI.

2. **“Guardrails recommender”**: generate a recommended `CREATE RESOURCE MONITOR` plan per warehouse based on trailing 30-day usage percentiles + anomaly detection, while clearly labeling gaps (serverless / cloud services suspension limitations).

3. **“Budget refresh-cost explainer”**: in-app lint that flags when a customer enables low-latency budgets and estimates the incremental budget compute cost (and why they might do it).

## Concrete Artifacts

### Artifact: SQL draft — warehouse-hour credits + optional query-tag attribution (allocation)

Goal: produce an *analytics-ready* table at hourly grain:
- `warehouse_metering_history` provides the **total** credits per (warehouse, hour)
- `query_history` can provide per-query execution_time + query_tag
- allocate the hour’s warehouse credits across query_tags proportionally to execution_time

This is **not** a perfect attribution mechanism (idle time and non-query work won’t be captured), but it is a pragmatic, explainable baseline for a FinOps Native App.

```sql
-- Parameters
--   :start_ts, :end_ts  (timestamps)
-- Notes:
--   * WAREHOUSE_METERING_HISTORY is hourly.
--   * Cloud services credits can be included in the warehouse metering view.
--   * If you want billed (vs consumed) cloud-services credits, reconcile separately via METERING_DAILY_HISTORY.

WITH wh_hour AS (
  SELECT
    start_time                         AS hour_start,
    end_time                           AS hour_end,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= :start_ts
    AND start_time <  :end_ts
    AND warehouse_id > 0  -- avoid pseudo warehouses (per Snowflake examples)
),
qh AS (
  SELECT
    DATE_TRUNC('hour', start_time)     AS hour_start,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '<NO_QUERY_TAG>') AS query_tag,
    SUM(execution_time)               AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= :start_ts
    AND start_time <  :end_ts
    AND warehouse_name IS NOT NULL
    AND execution_time > 0
  GROUP BY 1,2,3
),
qh_tot AS (
  SELECT
    hour_start,
    warehouse_name,
    SUM(exec_ms) AS total_exec_ms
  FROM qh
  GROUP BY 1,2
)
SELECT
  w.hour_start,
  w.warehouse_id,
  w.warehouse_name,
  q.query_tag,

  -- attribution basis
  q.exec_ms,
  t.total_exec_ms,

  -- allocated credits (proportional)
  IFF(t.total_exec_ms = 0, NULL, (q.exec_ms / t.total_exec_ms) * w.credits_used_compute)        AS alloc_credits_compute,
  IFF(t.total_exec_ms = 0, NULL, (q.exec_ms / t.total_exec_ms) * w.credits_used_cloud_services) AS alloc_credits_cloud_services,
  IFF(t.total_exec_ms = 0, NULL, (q.exec_ms / t.total_exec_ms) * w.credits_used)                AS alloc_credits_total
FROM wh_hour w
LEFT JOIN qh q
  ON q.hour_start = w.hour_start
 AND q.warehouse_name = w.warehouse_name
LEFT JOIN qh_tot t
  ON t.hour_start = w.hour_start
 AND t.warehouse_name = w.warehouse_name
;
```

### Artifact: ADR sketch — “Consumed vs billed” credit reporting in the Native App

**Context:** Many account usage views report *consumed* credits, but cloud services billing has a daily adjustment rule.  
**Decision:** The app will display two figures where relevant:
- “Consumed credits” (fast, granular) sourced from `WAREHOUSE_METERING_HISTORY` / `METERING_HISTORY` style views
- “Billed credits” (daily, reconciled) sourced from `METERING_DAILY_HISTORY`

**Status:** Proposed

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---:|---|
| Allocation by `execution_time` in `QUERY_HISTORY` is an approximation; warehouse idle time and some overhead won’t be attributed. | Per-team costs may under/over estimate; totals may not match expectations unless you add an “idle/unattributed” bucket. | Compare allocated credits sum vs hourly warehouse credits; report residual as `UNATTRIBUTED`. |
| Cloud services “consumed” vs “billed” mismatch can confuse users if not made explicit. | Loss of trust if app totals don’t match invoice. | Always label “consumed” vs “billed”; include a reconcile panel using `METERING_DAILY_HISTORY`. |
| Table function `WAREHOUSE_METERING_HISTORY()` is limited to last 6 months and may be incomplete for broad queries. | Backfills may miss history; incorrect long-range dashboards. | Prefer `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` for history; document retention/latency expectations per account. |
| Resource monitors do not fully control serverless and cloud services credit usage. | Guardrails might give a false sense of full cost control. | In UI copy + recommendations, explicitly call out coverage limitations (serverless + cloud services). |
| Low-latency budgets (1h refresh) increase the compute cost of budgets themselves. | Costs increase to monitor costs; could be counterproductive. | Surface the refresh tier and estimate budget compute cost delta (per Snowflake docs). |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY table function (6-month limit + recommendation to use `ACCOUNT_USAGE` for completeness): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view reference: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Exploring compute cost (consumed vs billed cloud services guidance; usage views + `METERING_DAILY_HISTORY`; `USAGE_IN_CURRENCY_DAILY`): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Resource monitors (notify/suspend behavior + limitations): https://docs.snowflake.com/en/user-guide/resource-monitors
5. Budgets (monthly spending limit; notification channels; refresh tier cost tradeoff; stored-procedure actions): https://docs.snowflake.com/en/user-guide/budgets

## Next Steps / Follow-ups

- Extend the artifact SQL to produce an explicit `UNATTRIBUTED` row per (warehouse, hour) capturing `wh_credits - SUM(alloc_credits)`.
- Decide whether the Native App’s primary drilldown surface is **query tags** (per team) or **object tags** (per resource), and define the join strategy accordingly.
- If we want true per-query credits (not proportional allocation), evaluate `QUERY_ATTRIBUTION_HISTORY` coverage and tradeoffs vs `QUERY_HISTORY` allocation (future note).
