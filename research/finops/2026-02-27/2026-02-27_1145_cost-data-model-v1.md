# Research: FinOps - 2026-02-27

**Time:** 11:45 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost data model v1: credits, attribution, guardrails)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, and includes separate compute vs cloud services columns plus an example for calculating **idle cost** as `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)`. Latency is up to **180 minutes** (and cloud services columns can be higher). 
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` returns **hourly** credit usage at the account level for the last **365 days**, broken down by `SERVICE_TYPE` (warehouses, many serverless features, SPCS, etc.). Latency is up to **180 minutes**, but some service types (e.g., Snowpipe Streaming) can be delayed longer.
3. `RESOURCE MONITORS` are a Snowflake object that can monitor and enforce credit quotas **for warehouses only** (not serverless / AI services). They can trigger notifications and/or suspend (immediately or after running statements complete). For serverless/AI, Snowflake docs explicitly point to using **budgets** instead.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `WAREHOUSE_NAME`, `QUERY_TAG`, timings, and a `CREDITS_USED_CLOUD_SERVICES` field for the statement; it also includes multiple queue time fields that can be used for performance/capacity signals.
5. `SNOWFLAKE.ORGANIZATION_USAGE` is a shared schema (in the `SNOWFLAKE` database) providing historical usage across accounts in an org, including `METERING_DAILY_HISTORY` and other views (some premium) with documented latencies.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly per-warehouse credits; includes compute vs cloud services; has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to separate execution from idle time. Retention 365d; latency up to ~3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly account credits by `SERVICE_TYPE` and optional entity fields; retention 365d; latency up to ~3h (some service types longer). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | `ACCOUNT_USAGE` | Query-level history; includes `QUERY_TAG`, `WAREHOUSE_NAME`, queueing + execution timings, bytes scanned; includes statement cloud-services credits field. |
| `SNOWFLAKE.ORGANIZATION_USAGE` (various views) | schema | `ORG_USAGE` | Org-level view inventory; includes metering, contracts, currency anomalies, resource monitors, etc. Some premium; latencies vary (e.g., 2h/24h/72h depending on view). |
| `RESOURCE MONITORS` | object | Snowflake object type | Enforces credit quotas for warehouses only; can suspend warehouses as action; schedule resets at 12:00 AM UTC. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Hourly cost spine + attribution baseline:** build a canonical `fact_credit_usage_hourly` from `ACCOUNT_USAGE.METERING_HISTORY` + `WAREHOUSE_METERING_HISTORY` (warehouse slice), so the app can show “Total credits by service type” + “Warehouse breakdown” with consistent time buckets.
2. **Idle cost KPI per warehouse:** use the documented formula from `WAREHOUSE_METERING_HISTORY` to compute idle credits and trend it (top idle warehouses, idle% by day/week). This is low-risk, doc-backed, and works without query-level attribution.
3. **Guardrails insights:** detect (a) warehouses without any resource monitor, (b) resource monitors that only `NOTIFY` but never `SUSPEND`, and (c) quotas that reset monthly but spend is weekly-bursty; recommend adjustments. (Note: enforcement is warehouses-only; for serverless/AI we should route users to budgets.)

## Concrete Artifacts

### Artifact: Cost data model v1 (warehouse + account metering) + idle cost view

Goal: A minimal schema our Native App can maintain to power cost dashboards and anomaly detection.

```sql
-- Cost Model v1 (draft)
-- Assumptions:
-- - We normalize all timestamps to UTC to simplify joins across ACCOUNT_USAGE/ORG_USAGE.
-- - We treat "credits" as the base unit; currency conversion is a later layer.

-- 1) Hourly warehouse credits + idle credits
create or replace view FINOPS.FACT_WAREHOUSE_CREDITS_HOURLY as
select
  /* hourly bucket */
  date_trunc('hour', start_time)::timestamp_ntz as hour_utc,
  warehouse_id,
  warehouse_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_attributed_compute_queries,
  /* Doc-backed idle cost formula */
  (credits_used_compute - credits_attributed_compute_queries) as credits_idle_compute
from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY;

-- 2) Hourly account metering by service type
create or replace view FINOPS.FACT_METERING_HOURLY as
select
  date_trunc('hour', start_time)::timestamp_ntz as hour_utc,
  service_type,
  entity_type,
  entity_id,
  name,
  database_name,
  schema_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  bytes,
  rows,
  files
from SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY;

-- 3) A simple daily idle% KPI per warehouse (for leaderboard + alerting)
create or replace view FINOPS.KPI_WAREHOUSE_IDLE_DAILY as
select
  date_trunc('day', hour_utc)::date as day_utc,
  warehouse_name,
  sum(credits_used_compute) as credits_compute,
  sum(credits_idle_compute) as credits_idle_compute,
  iff(sum(credits_used_compute) = 0, null,
      sum(credits_idle_compute) / sum(credits_used_compute)) as idle_ratio
from FINOPS.FACT_WAREHOUSE_CREDITS_HOURLY
group by 1,2;

-- Optional: query-level context table to enable future attribution
-- (not joined here yet; keep separate until we decide on attribution rules).
create or replace view FINOPS.DIM_QUERY_CONTEXT as
select
  query_id,
  start_time::timestamp_ntz as start_time_utc,
  end_time::timestamp_ntz as end_time_utc,
  user_name,
  role_name,
  warehouse_name,
  query_tag,
  query_type,
  execution_status,
  total_elapsed_time,
  queued_overload_time,
  queued_provisioning_time,
  queued_repair_time,
  bytes_scanned,
  credits_used_cloud_services
from SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` latencies (3–6h typical, sometimes longer) mean “real time” dashboards will be delayed. | Users may expect minute-level cost. | Clearly label freshness; optionally supplement with other telemetry for near-real-time (TBD). Docs list explicit latency notes for views. |
| Resource monitors only cover warehouses (not serverless / AI services). | If the app recommends monitors as a universal control, it will be wrong. | Snowflake resource monitor docs explicitly state warehouses-only and point to budgets for serverless/AI. |
| Attribution of compute cost to teams/queries beyond idle cost will require a policy (query_tag conventions, role mapping, warehouse ownership, etc.). | Without a policy, “chargeback” may be disputed. | Start with low-dispute KPIs (idle, top warehouses, service-type spend). Add attribution as opt-in with clear rules. |
| ORG_USAGE view availability can depend on org setup / premium views. | Feature parity may vary across customers. | Detect availability at install/runtime and degrade gracefully. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY view (columns, latency, idle cost example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. METERING_HISTORY view (service_type breakdown, columns, latency notes): https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. Working with resource monitors (warehouses-only enforcement, actions, reset schedule): https://docs.snowflake.com/en/user-guide/resource-monitors
4. QUERY_HISTORY view (query_tag, warehouse, timings, statement cloud-services credits): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
5. Organization Usage schema (inventory of ORG_USAGE views including metering daily history): https://docs.snowflake.com/en/sql-reference/organization-usage

## Next Steps / Follow-ups

- Decide whether cost-model v1 should live in an app-managed database/schema (e.g., `FINOPS`) or in a customer-provided schema; document required grants.
- Add a second research pass on **Budgets** (to complement resource monitors for serverless/AI services) and map “controls” coverage across service types.
- Define an attribution strategy hierarchy (query_tag → role_name → warehouse_name → fallback) and capture it as an ADR.
