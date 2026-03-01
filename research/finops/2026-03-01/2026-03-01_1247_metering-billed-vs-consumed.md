# Research: FinOps - 2026-03-01

**Time:** 12:47 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake distinguishes between **credits consumed** vs **credits actually billed** for some components of compute cost; specifically, **cloud services** credits are billed only if daily cloud services consumption exceeds **10%** of daily virtual warehouse usage. (Exploring compute cost doc)  
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage for the account for the last **365 days**, broken down by `SERVICE_TYPE` (e.g., `WAREHOUSE_METERING`, `PIPE`, `AUTO_CLUSTERING`, `SNOWPARK_CONTAINER_SERVICES`, etc.). It includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_USED` (sum) but **does not apply** the cloud services billing adjustment. (METERING_HISTORY doc)
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative rebate) and `CREDITS_BILLED` (used compute + used cloud services + adjustment). This is the primitive to use when building “actual billed credits” dashboards for compute. (METERING_DAILY_HISTORY doc; Exploring compute cost doc)
4. `WAREHOUSE_METERING_HISTORY` exists in two common forms with different completeness windows:  
   - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (view) is typically used for longer windows (docs referenced by Exploring compute cost examples).  
   - `WAREHOUSE_METERING_HISTORY(...)` (Information Schema table function) returns credit usage within the last **6 months** and may be incomplete for long ranges / many warehouses; use the ACCOUNT_USAGE view for completeness. (WAREHOUSE_METERING_HISTORY function doc)
5. Usage views have **latency**; for example, `ACCOUNT_USAGE.METERING_HISTORY` can lag up to **~180 minutes** (and some columns/service types longer), and `ACCOUNT_USAGE.METERING_DAILY_HISTORY` can lag up to **~180 minutes**. Plan any FinOps alerting/spike detection with these lags in mind. (METERING_HISTORY doc; METERING_DAILY_HISTORY doc)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by `SERVICE_TYPE` for last 365 days; includes `CREDITS_USED_*` but not billed-adjusted totals. Latency up to ~180 mins (cloud services column can lag longer; some service types lag longer). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits + **cloud services adjustment** (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`, negative) and `CREDITS_BILLED` for last 365 days. Notes mention setting session timezone to UTC when reconciling with ORG usage views. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; used for warehouse-level compute patterns and cloud services portion (examples in Exploring compute cost). |
| `WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFORMATION_SCHEMA` | Hourly warehouse credits in last 6 months; can be incomplete for long/large queries; requires `ACCOUNTADMIN` or `MONITOR USAGE` privilege; requires `INFORMATION_SCHEMA` in use (or fully-qualified). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“Billed vs consumed” reconciliation widget**: show daily `CREDITS_BILLED` (from `METERING_DAILY_HISTORY`) vs daily sum of hourly `METERING_HISTORY.CREDITS_USED` to teach users why dashboards disagree (cloud services adjustment + latency).
2. **Cloud services billing detector**: per-day flag when cloud services credits are actually billed (vs fully rebated) using `METERING_DAILY_HISTORY` fields; use this to route investigations to compilation/listing/external file listing / cloning patterns.
3. **Service-type drilldown for serverless cost**: use `METERING_HISTORY` for hourly `SERVICE_TYPE` slices (e.g., `SEARCH_OPTIMIZATION`, `AUTO_CLUSTERING`, `PIPE`, `SERVERLESS_TASK`, `SNOWPARK_CONTAINER_SERVICES`) as the “where did credits go?” entrypoint.

## Concrete Artifacts

### View: Daily compute credits (billed vs consumed) + cloud services adjustment

Goal: provide an app-ready view that separates:
- **consumed** credits (hourly rollup) vs
- **billed** credits (daily) with cloud services adjustment,

and highlights days where cloud services were actually billed.

```sql
-- Create an app-owned schema (example)
CREATE SCHEMA IF NOT EXISTS FINOPS;

-- Daily *billed* credits (includes cloud services adjustment)
CREATE OR REPLACE VIEW FINOPS.V_COMPUTE_BILLED_DAILY AS
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed,
  -- Cloud services billed amount for the day (can be 0 when fully rebated)
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services,
  IFF((credits_used_cloud_services + credits_adjustment_cloud_services) > 0, TRUE, FALSE) AS cloud_services_were_billed
FROM snowflake.account_usage.metering_daily_history;

-- Daily *consumed* credits, rolled up from hourly metering_history
-- NOTE: this is *consumed* credits; it does not apply cloud services adjustment.
CREATE OR REPLACE VIEW FINOPS.V_COMPUTE_CONSUMED_DAILY AS
SELECT
  TO_DATE(start_time) AS usage_date,
  service_type,
  SUM(credits_used_compute)         AS credits_used_compute,
  SUM(credits_used_cloud_services)  AS credits_used_cloud_services,
  SUM(credits_used)                AS credits_used_total
FROM snowflake.account_usage.metering_history
GROUP BY 1, 2;

-- Combined view (join billed vs consumed by day + service_type)
CREATE OR REPLACE VIEW FINOPS.V_COMPUTE_BILLED_VS_CONSUMED_DAILY AS
SELECT
  COALESCE(b.usage_date, c.usage_date) AS usage_date,
  COALESCE(b.service_type, c.service_type) AS service_type,

  -- Billed (daily, adjusted)
  b.credits_billed,
  b.billed_cloud_services,
  b.cloud_services_were_billed,

  -- Consumed (hourly rollup)
  c.credits_used_total               AS credits_consumed_total,
  c.credits_used_compute             AS credits_consumed_compute,
  c.credits_used_cloud_services      AS credits_consumed_cloud_services,

  -- Diagnostic: difference (primarily cloud services adjustment + timing/latency)
  (c.credits_used_total - b.credits_billed) AS consumed_minus_billed
FROM FINOPS.V_COMPUTE_BILLED_DAILY b
FULL OUTER JOIN FINOPS.V_COMPUTE_CONSUMED_DAILY c
  ON b.usage_date = c.usage_date
 AND b.service_type = c.service_type;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hourly rollups from `METERING_HISTORY` won’t reconcile to billed totals because of cloud services adjustment + view latency. | Users may think the app is “wrong” if we don’t explain it. | Use the combined view above and explicitly label “consumed” vs “billed”. Cite docs + add tooltips. |
| `WAREHOUSE_METERING_HISTORY` exists as both a view and a table function with different time windows (table function: last 6 months). | If the app accidentally uses the table function, longer lookbacks may silently truncate. | Standardize on `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` for app analytics; reserve table function for ad-hoc / perf-sensitive slices. |
| `ACCOUNT_USAGE` views have hours of latency. | “Real-time” alerts will be delayed; spike detection needs slack. | Communicate expected latency; for near-real-time, consider event tables / query logs (separate research track). |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
4. https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Add an app UX pattern: **“Consumed vs Billed” explainer** (cloud services 10% rule + adjustment) and link to Snowflake docs.
- Extend the artifact to also join `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` for currency reporting (org-level only; needs separate citation pass).
- Add service-type-specific drilldowns: show top `SERVICE_TYPE` movers week-over-week using `METERING_HISTORY`.
