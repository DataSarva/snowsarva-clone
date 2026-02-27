# Research: FinOps - 2026-02-27

**Time:** 18:06 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage for an account for the **last 365 days**, with per-row breakdown by `SERVICE_TYPE` and additional attribution fields like `ENTITY_TYPE`, `NAME`, `DATABASE_NAME`, `SCHEMA_NAME`. Latency is typically up to **180 minutes**, with some fields/types taking longer (e.g., cloud services up to 6h; Snowpipe Streaming up to 12h).  
   Source: Snowflake docs for `METERING_HISTORY`. [1]

2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage at the **warehouse** level (for one or all warehouses) for the **last 365 days**. The view includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (which excludes idle time). It also calls out that `CREDITS_USED` might exceed billed credits due to cloud-services adjustment; for billed reconciliation, use daily metering views (e.g., `METERING_DAILY_HISTORY`).  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`. [2]

3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily** usage for an organization in **credits and currency**, with fields like `USAGE_DATE` (UTC), `USAGE` (units depend on `RATING_TYPE`), and `USAGE_IN_CURRENCY`. Data can have up to **72 hours** latency, can change before month close due to adjustments, and is retained indefinitely; some customers (e.g., reseller contracts) can’t access it.  
   Source: Snowflake docs for `USAGE_IN_CURRENCY_DAILY`. [3]

4. Snowflake **Resource Monitors** help control cost by monitoring **warehouse** credit usage and can trigger notifications/suspensions based on thresholds. Resource monitors **do not** track serverless features or AI services; to monitor those, Snowflake docs recommend using a **budget** instead.  
   Source: Snowflake docs on Resource Monitors. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account usage by `SERVICE_TYPE`; retained 365 days; latency up to 180m+; includes attribution fields (`ENTITY_TYPE`, `NAME`, db/schema). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly per-warehouse usage; retained 365 days; has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily usage in currency at org scope; higher latency (up to 72h) and can be adjusted until month close. [3] |
| Resource Monitor object | Object | N/A (account object) | Controls/alerts/suspends **warehouses only**; does not cover serverless/AI usage. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost “fact” table MVP (credits):** ingest hourly `WAREHOUSE_METERING_HISTORY` + hourly `METERING_HISTORY` into an app-owned schema, standardize to UTC, and materialize a daily rollup. This unlocks per-warehouse trend lines + non-warehouse service spend breakdown.

2. **Idle-cost lens:** compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` per warehouse per day (or hour) and surface “top idle warehouses.” (Snowflake docs provide a reference example query.) [2]

3. **Org-level currency reconciliation (optional):** if customer has ORG_USAGE access, join/sanity-check account credit totals vs `USAGE_IN_CURRENCY_DAILY` for finance-facing reporting (explicitly handling “data can change before month close”). [3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: SQL draft — build a minimal daily cost model (warehouse + service-type)

Assumptions:
- The Native App (or associated setup script) creates an internal database/schema like `APP_COST.INT`.
- For cross-source reconciliation, we standardize timestamps to **UTC** (Snowflake docs explicitly call out timezone considerations when reconciling with org usage views). [2]

```sql
-- 0) (Optional but recommended) Standardize session timezone to UTC for consistent rollups.
-- Snowflake docs: reconcile ACCOUNT_USAGE with ORG_USAGE requires UTC session. [2]
ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Daily per-warehouse metering + idle credits.
CREATE OR REPLACE TABLE APP_COST.INT.FCT_WAREHOUSE_CREDITS_DAILY AS
SELECT
  TO_DATE(start_time)                                  AS usage_date_utc,
  warehouse_id,
  warehouse_name,
  SUM(credits_used_compute)                            AS credits_compute,
  SUM(credits_used_cloud_services)                     AS credits_cloud_services,
  SUM(credits_used)                                    AS credits_total_unadjusted,
  SUM(credits_attributed_compute_queries)              AS credits_attributed_queries,
  (SUM(credits_used_compute) -
   SUM(credits_attributed_compute_queries))            AS credits_idle_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY 1, 2, 3;

-- 2) Daily service-type spend (account-level) for non-warehouse/serverless/AI/etc.
-- NOTE: METERING_HISTORY credits may not match billed credits due to adjustment; treat as "usage".
CREATE OR REPLACE TABLE APP_COST.INT.FCT_SERVICE_CREDITS_DAILY AS
SELECT
  TO_DATE(start_time)                                  AS usage_date_utc,
  service_type,
  entity_type,
  name,
  database_name,
  schema_name,
  SUM(credits_used_compute)                            AS credits_compute,
  SUM(credits_used_cloud_services)                     AS credits_cloud_services,
  SUM(credits_used)                                    AS credits_total_unadjusted
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY 1, 2, 3, 4, 5, 6;

-- 3) (Optional) Daily currency usage for org-level reporting.
-- Only works if the customer’s org/contract allows access. [3]
CREATE OR REPLACE TABLE APP_COST.INT.FCT_ORG_USAGE_IN_CURRENCY_DAILY AS
SELECT
  organization_name,
  contract_number,
  account_locator,
  account_name,
  region,
  usage_date                                         AS usage_date_utc,
  rating_type,
  service_type,
  billing_type,
  is_adjustment,
  SUM(usage)                                         AS usage_units,
  ANY_VALUE(currency)                                AS currency,
  SUM(usage_in_currency)                             AS usage_in_currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE usage_date >= DATEADD('day', -60, CURRENT_DATE())
GROUP BY 1,2,3,4,5,6,7,8,9,10;
```

### Artifact: Mini-ADR — “two-tier truth” for FinOps reporting

**Decision:** Maintain two explicit “truth tiers” in the app’s data model:
- **Tier A (near-real-time operational):** `ACCOUNT_USAGE` hourly views for fast anomaly detection and workload steering.
- **Tier B (finance/reconciliation):** `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` when available, acknowledging latency and month-close adjustments.

**Rationale:**
- `ACCOUNT_USAGE` gives granular operational levers (warehouse-level, service-type, object attribution) with relatively low latency (hours). [1][2]
- Currency/billing reconciliation is more naturally supported by ORG_USAGE daily currency view, but it has longer latency and can change pre-close. [3]

**Implications for product UX:**
- Dashboards should label freshness and “may change” clearly.
- Alerting should use Tier A; monthly reports can reconcile with Tier B when present.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` exists for all customers | Feature gaps for reseller contracts / accounts without org access | Detect access at install-time; fall back to credit-based reporting; surface “currency reporting unavailable” with reason. [3] |
| Treating `METERING_HISTORY.CREDITS_USED` as billed credits | Misleading finance numbers if shown as “bill” | Label as “usage credits (unadjusted)”; optionally reconcile using daily billing-oriented views or ORG_USAGE currency view. [2][3] |
| Latency windows for cost signals | Late alerts or false negatives for fast spikes | Bake in lag-aware alerting windows (e.g., look back 6–12h depending on service type). [1][2][3] |
| Resource Monitors cover “all spend” | Blind spot for serverless/AI | Use budgets or account usage views for serverless/AI monitoring; message clearly in UX. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
4. https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Identify the best “billing-reconcilable” daily view(s) for credits billed at the account level (e.g., `METERING_DAILY_HISTORY`, mentioned by the warehouse view docs) and add them as Tier B fallback when ORG_USAGE is unavailable. [2]
- Extend the cost model with tags/attribution (warehouse owner/team), likely via query history + warehouse mapping (separate research lane).
- Decide app UX for “freshness badges” and “month-close adjustment” messaging.
