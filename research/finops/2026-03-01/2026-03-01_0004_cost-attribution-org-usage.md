# Research: FinOps - 2026-03-01

**Time:** 00:04 UTC  
**Topic:** Snowflake FinOps Cost Attribution across ORG_USAGE vs ACCOUNT_USAGE (credits used vs billed)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, but `CREDITS_USED` may be **greater than billed** because it does **not** include the cloud services adjustment; billed credits should be derived from `METERING_DAILY_HISTORY`. (Snowflake docs) [1] [4]
2. `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` provides the same type of **hourly warehouse credit usage**, but **across all accounts in the organization**; latency may be **up to 24 hours**. (Snowflake docs) [3]
3. To **reconcile** `ACCOUNT_USAGE` with `ORGANIZATION_USAGE` views, Snowflake explicitly recommends setting session timezone to **UTC** before querying the Account Usage view. (Snowflake docs) [1] [4]
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage **and** a cloud services rebate/adjustment, including `CREDITS_BILLED = CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES + CREDITS_ADJUSTMENT_CLOUD_SERVICES`. (Snowflake docs) [4]
5. Resource monitors help control costs by monitoring **warehouse** credit usage and can notify/suspend warehouses, but they **do not** track serverless features / AI services; Snowflake recommends **budgets** for that broader scope. (Snowflake docs) [5] [6]
6. Budgets define a **monthly spending limit** (credits) for an account or a custom group of objects and can notify via email / cloud queue / webhook; budgets refresh interval defaults up to **6.5 hours** and can be reduced to **1 hour** at increased cost. (Snowflake docs) [6]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits used; `CREDITS_USED` is not billed-adjusted; latency up to 180 min (cloud services column up to 6 hours). Reconciliation note: set TZ=UTC. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Hourly warehouse credits used across all accounts; latency up to 24h. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits; includes cloud services adjustment + `CREDITS_BILLED`. Reconciliation note: set TZ=UTC. [4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Daily credits across org; includes adjustment + `CREDITS_BILLED`. [7] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributes include `WAREHOUSE_NAME` and `QUERY_TAG` for attribution dimensions. (Costs per query not directly present here.) [2] |
| `RESOURCE MONITOR` | Object | N/A (DDL object) | Warehouse-only guardrails (notify/suspend); not for serverless/AI. [5] |
| `BUDGET` | Object/Class | N/A (cost mgmt feature) | Monthly spend guardrail; supports notification integrations; can trigger stored procedures as actions. [6] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide hourly warehouse cost dashboard (used credits)**: build a canonical table (in app-owned database) that snapshots `ORG_USAGE.WAREHOUSE_METERING_HISTORY` daily and powers “Top warehouses by credits” across accounts. (Latency-tolerant due to 24h lag.) [3]
2. **Billed vs used credit reconciliation widget**: daily view that compares `WAREHOUSE_METERING_HISTORY.CREDITS_USED` (hourly aggregated) vs `METERING_DAILY_HISTORY.CREDITS_BILLED` (daily) and explains the cloud services adjustment. [1] [4]
3. **Guardrail recommendations**: UI that detects “warehouse dominates spend” → recommends Resource Monitor; detects “serverless / AI / other service types dominate spend” → recommends Budgets (and shows trade-off of 1h refresh tier cost). [5] [6]

## Concrete Artifacts

### SQL draft: Org-wide hourly warehouse credits (with account dimension) + daily billed overlay

**Intent:** produce a dataset that powers (a) org-wide top warehouses by used credits, and (b) overlays billed credits by day for context.

```sql
-- Org-wide hourly warehouse credits used
-- Source: SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes: This is *used* credits, not billed-adjusted. [3]

WITH hourly AS (
  SELECT
    organization_name,
    account_name,
    region,
    warehouse_name,
    -- Recommended to normalize time handling; doc reconciliation guidance emphasizes UTC. [1][4]
    start_time::timestamp_ltz AS hour_start,
    end_time::timestamp_ltz   AS hour_end,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services
  FROM snowflake.organization_usage.warehouse_metering_history
  WHERE start_time >= dateadd('day', -30, current_timestamp())
),

-- Daily billed credits (all service types) by account
-- Source: SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY includes CREDITS_BILLED. [7]

daily_billed AS (
  SELECT
    organization_name,
    account_name,
    region,
    usage_date,
    sum(credits_billed) AS credits_billed_all_services
  FROM snowflake.organization_usage.metering_daily_history
  WHERE usage_date >= dateadd('day', -30, current_date())
  GROUP BY 1,2,3,4
)

SELECT
  h.organization_name,
  h.account_name,
  h.region,
  h.warehouse_name,
  date_trunc('day', h.hour_start) AS usage_date,
  sum(h.credits_used)            AS warehouse_credits_used,
  sum(h.credits_used_compute)    AS warehouse_credits_used_compute,
  sum(h.credits_used_cloud_services) AS warehouse_credits_used_cloud_services,
  b.credits_billed_all_services
FROM hourly h
LEFT JOIN daily_billed b
  ON b.organization_name = h.organization_name
 AND b.account_name      = h.account_name
 AND b.region            = h.region
 AND b.usage_date        = date_trunc('day', h.hour_start)
GROUP BY 1,2,3,4,5,9
ORDER BY usage_date DESC, warehouse_credits_used DESC;
```

### Attribution hook: Query tags as a FinOps dimension (ACCOUNT_USAGE)

```sql
-- Query tag is present in ACCOUNT_USAGE.QUERY_HISTORY and can be used as a cost attribution dimension.
-- This query builds *activity* metrics that can later be joined to warehouse metering.
-- NOTE: QUERY_HISTORY does not directly include credits per query; attribution must be modeled.

SELECT
  date_trunc('day', start_time) AS usage_date,
  warehouse_name,
  query_tag,
  count(*) AS query_count,
  sum(total_elapsed_time) / 1000.0 AS total_elapsed_seconds,
  sum(bytes_scanned) AS bytes_scanned
FROM snowflake.account_usage.query_history
WHERE start_time >= dateadd('day', -30, current_timestamp())
  AND warehouse_name IS NOT NULL
GROUP BY 1,2,3
ORDER BY usage_date DESC, query_count DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Org-level views (`ORG_USAGE`) may require elevated org-level privileges that a Native App may not have by default. | Limits “single pane of glass” across accounts; may need per-account installation or customer-provided data share into a central account. | Confirm required privileges + whether a Native App can access `SNOWFLAKE.ORGANIZATION_USAGE` in consumer accounts; test in a real org. |
| Mapping “billed credits” back to specific warehouses is non-trivial because `METERING_DAILY_HISTORY` is by `SERVICE_TYPE` and day (not warehouse). | UI might show mismatched totals if users expect exact per-warehouse billed credits. | Make explicit in product: “used credits by warehouse” vs “billed credits by service type/day”. Cite docs and add reconciliation notes. [1][4][7] |
| Latency differences (up to 24h in org hourly warehouse metering) can frustrate near-real-time monitoring use cases. | Alerts/anomaly detection may be delayed. | Provide “data freshness” indicator; use budgets (up to 6.5h default) for earlier detection when appropriate. [3][6] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
5. https://docs.snowflake.com/en/user-guide/resource-monitors
6. https://docs.snowflake.com/en/user-guide/budgets
7. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history

## Next Steps / Follow-ups

- Validate required privileges + Native App feasibility for reading `SNOWFLAKE.ORGANIZATION_USAGE.*` directly (or design an alternative ingestion pattern).
- Decide on product vocabulary + UI: “used credits” vs “billed credits”, and show the cloud services adjustment explanation (doc-backed). [1][4]
- Prototype a small db schema in the app to persist the “hourly warehouse used credits” snapshot + compute rolling z-score anomalies per warehouse/account.
