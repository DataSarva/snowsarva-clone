# FinOps Research Note — Native App Cost/Metering: combine ACCOUNT_USAGE credits + Custom Event Billing

- **When (UTC):** 2026-02-01 14:56
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs to (a) attribute Snowflake credit spend to teams/apps/workloads and (b) optionally support provider-side monetization for the app itself (marketplace listing). Snowflake provides different primitives for these: ACCOUNT_USAGE/ORG_USAGE views for *Snowflake consumption*, and **Custom Event Billing** system functions for *marketplace billing events*.

## Accurate takeaways
- **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** provides *hourly* credit usage per warehouse (last 365 days). It includes `CREDITS_USED` (= compute + cloud services) and additional attribution columns like `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. Latency can be up to ~180 minutes for most columns; `CREDITS_USED_CLOUD_SERVICES` can lag up to ~6 hours.  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- For marketplace monetization, **Custom Event Billing** for Snowflake Native Apps is implemented by calling **`SYSTEM$CREATE_BILLING_EVENT`** or batching via **`SYSTEM$CREATE_BILLING_EVENTS`** from within app stored procedures running in the *consumer account*. Snowflake explicitly notes that billable events must be emitted by calling the system function from within stored procedures and that other approaches (e.g., “base charge from telemetry logged in an event table”) are not supported.  
  Source: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing
- Providers can monitor consumer app health by calling **`SYSTEM$REPORT_HEALTH_STATUS(VARCHAR)`** from the app and then reading `LAST_HEALTH_STATUS` / `LAST_HEALTH_STATUS_UPDATED_ON` from the **APPLICATION_STATE** view.  
  Source: https://docs.snowflake.com/en/developer-guide/native-apps/monitoring
- Snowflake’s Well-Architected cost guidance emphasizes treating cost as a design constraint, building baselines/benchmarks (e.g., credits per 1K queries), and implementing visibility + control frameworks (resource monitors/budgets/tagging policies).  
  Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE) — hourly warehouse credits (`CREDITS_USED`, etc.).
- `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` (ACCOUNT_USAGE) — needed to reconcile *billed* credits vs raw metering (docs for WAREHOUSE_METERING_HISTORY point here).
- `SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE` (DATA_SHARING_USAGE) — provider monitoring fields like `LAST_HEALTH_STATUS` / `LAST_HEALTH_STATUS_UPDATED_ON` for consumer app instances. (Referenced in monitoring doc.)
- (For deeper attribution, likely) `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` + tagging metadata (exact join patterns depend on whether tagging is enabled + which tag views are available).

## MVP features unlocked (PR-sized)
1) **Warehouse cost “shape” + idle ratio dashboard (hourly):** Build a view that computes per-warehouse hourly credits, query-attributed credits, and “idle credits” = (total - attributed). Use this to rank warehouses by idle waste and generate “turn on auto-suspend / right-size” recommendations.
2) **Native App provider health panel:** If we’re also building provider tooling, implement a lightweight “health heartbeat” procedure that calls `SYSTEM$REPORT_HEALTH_STATUS('OK'|'FAILED'|'PAUSED')` and surface consumer instance status via APPLICATION_STATE.
3) **(If marketplace listing) Custom Event Billing instrumentation kit:** Provide a reference stored-procedure wrapper for `SYSTEM$CREATE_BILLING_EVENT(S)` and a design checklist that ensures the billing base charge is computed inside supported stored-proc codepaths.

## Heuristics / detection logic (v1)
- **Idle waste:** for each warehouse-hour, compute:
  - `idle_credits = CREDITS_USED - CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (check column availability and semantics in your account)  
  - `idle_ratio = idle_credits / NULLIF(CREDITS_USED,0)`
  Flag warehouses with sustained idle_ratio > 0.3 across business hours.
- **Cost baseline drift:** compute rolling 7-day median `credits_per_hour` per warehouse; alert on 2x spikes.
- **Health signal:** alert if APPLICATION_STATE shows `LAST_HEALTH_STATUS != 'OK'` OR stale `LAST_HEALTH_STATUS_UPDATED_ON` beyond a threshold.

## Security/RBAC notes
- ACCOUNT_USAGE views generally require account-level privileges (and often `MONITOR USAGE` or higher depending on exact object). Plan to ship a least-privilege role recipe for the app’s data-collection routines.
- For Native App monitoring and custom event billing, calls happen *inside the app* in the consumer account; ensure stored procedures are scoped to the minimum required privileges and do not exfiltrate consumer data.

## Concrete artifact (SQL draft)
### 1) Hourly warehouse idle-credits view (ACCOUNT_USAGE)
```sql
-- v1: warehouse hourly metering + idle estimate
-- Notes:
-- - This uses ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, which can lag (3h+).
-- - "Idle credits" is a heuristic: total metered credits minus credits attributed to compute queries.

create or replace view FINOPS.PUBLIC.V_WAREHOUSE_IDLE_HOURLY as
select
  start_time,
  end_time,
  warehouse_name,
  credits_used,
  credits_used_compute,
  credits_used_cloud_services,
  credits_attributed_compute_queries,
  greatest(credits_used - credits_attributed_compute_queries, 0) as idle_credits_est,
  (greatest(credits_used - credits_attributed_compute_queries, 0)
    / nullif(credits_used, 0))::float as idle_ratio_est
from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
where start_time >= dateadd('day', -14, current_timestamp());
```

### 2) Provider monitoring query (Native Apps)
```sql
-- Provider-side monitoring for consumer app instances
-- (fields referenced by Snowflake monitoring docs)
select
  application_name,
  consumer_account_name,
  last_health_status,
  last_health_status_updated_on
from SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE
order by last_health_status_updated_on desc;
```

## Risks / assumptions
- Column availability in `WAREHOUSE_METERING_HISTORY` can vary by schema/context; validate that `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` is present in your account and confirm semantics.
- “Idle credits” is an approximation; it won’t capture all causes (e.g., background services, non-query compute depending on workload patterns).
- Custom Event Billing is *not* a general-purpose internal chargeback mechanism; it’s specifically for paid listings / billing events and must be emitted via supported stored procedure calls (not event table telemetry).

## Links / references
- WAREHOUSE_METERING_HISTORY view (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- Add billable events to an app (Custom Event Billing): https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing
- Use monitoring for an app (SYSTEM$REPORT_HEALTH_STATUS + APPLICATION_STATE): https://docs.snowflake.com/en/developer-guide/native-apps/monitoring
- Snowflake Well-Architected: Cost Optimization & FinOps: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
