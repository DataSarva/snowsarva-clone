# Research: FinOps - 2026-03-01

**Time:** 08:40 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credits used per warehouse for up to **365 days**, but the `CREDITS_USED` column is a sum of compute + cloud services **and may be greater than what is billed** because it does **not** account for the daily cloud services adjustment; Snowflake directs you to use `METERING_DAILY_HISTORY` to determine billed credits. (Cited)  
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` contains `CREDITS_BILLED`, which includes the daily **cloud services adjustment** (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`, negative) and is the most direct “what was billed” metric at daily grain. (Cited)  
3. Cloud services are **billed only if** daily cloud services consumption exceeds **10%** of daily virtual warehouse usage (adjustment is calculated daily in UTC); therefore, most “credits used” views (including warehouse metering) are better treated as **consumption telemetry**, not necessarily **invoice-reconcilable billing**. (Cited)  
4. Reconciling ACCOUNT_USAGE views with their ORGANIZATION_USAGE counterparts requires setting the session timezone to UTC (`ALTER SESSION SET TIMEZONE = UTC;`) before querying ACCOUNT_USAGE. (Cited)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits used (compute + cloud services). Latency up to ~3h. `CREDITS_USED` may exceed billed; use `METERING_DAILY_HISTORY` for billed. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Hourly warehouse credits used across org accounts; latency up to ~24h; includes `ACCOUNT_NAME`, `REGION`, `ACCOUNT_LOCATOR`. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits used + cloud services adjustment + `CREDITS_BILLED`. Latency up to ~3h. Contains `SERVICE_TYPE`. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | ORG_USAGE | Daily org-wide equivalent; latency up to ~2h; includes org/account identifiers. |

## MVP Features Unlocked

1. **Billed-vs-Consumed toggle everywhere (foundational UX):** For any “spend” chart, let the user select **Consumed credits** (hourly, warehouse attribution possible) vs **Billed credits** (daily, invoice-reconcilable). Under the hood: `WAREHOUSE_METERING_HISTORY` vs `METERING_DAILY_HISTORY`.
2. **Daily Cloud Services Billing Explainer:** show per-day: `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_ADJUSTMENT_CLOUD_SERVICES`, and computed `BILLED_CLOUD_SERVICES = CREDITS_USED_CLOUD_SERVICES + CREDITS_ADJUSTMENT_CLOUD_SERVICES` (can be 0), with the 10% rule contextual text.
3. **Reconciliation Mode (Account ↔ Org):** Provide a “Reconcile with ORG_USAGE” tool that (a) forces UTC session, and (b) runs a canned reconciliation query to compare aggregates between ACCOUNT_USAGE and ORG_USAGE for a time range.

## Concrete Artifacts

### Daily compute cost fact: billed vs consumed (app-ready view)

Purpose: produce a single daily table/view that supports:
- invoice-reconcilable billing (`CREDITS_BILLED`), and
- operational consumption telemetry (`CREDITS_USED` broken down by service_type).

```sql
-- FINOPS.FACT_COMPUTE_CREDITS_DAILY
-- Daily grain; invoice-aligned via CREDITS_BILLED.
-- NOTE: ACCOUNT_USAGE views can have latency; design pipelines accordingly.

CREATE OR REPLACE VIEW FINOPS.FACT_COMPUTE_CREDITS_DAILY AS
SELECT
  usage_date,
  service_type,

  -- consumption telemetry
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,

  -- billing adjustment + billed
  credits_adjustment_cloud_services,
  credits_billed,

  -- derived helper fields
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services_credits
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -365, CURRENT_DATE());
```

### Warehouse hourly consumption and daily billed overlay (diagnostic)

Useful for “why did my bill jump?” triage: compare daily sum of warehouse-hour `CREDITS_USED` to daily `CREDITS_BILLED` (all service types) and isolate cloud services adjustment.

```sql
-- Ensure UTC before doing ACCOUNT_USAGE ↔ ORG_USAGE reconciliation.
ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_daily AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used) AS wh_credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1
),
all_compute_daily AS (
  SELECT
    usage_date,
    SUM(credits_used) AS total_credits_used,
    SUM(credits_billed) AS total_credits_billed,
    SUM(credits_used_cloud_services) AS cloud_services_used,
    SUM(credits_adjustment_cloud_services) AS cloud_services_adjustment
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1
)
SELECT
  d.usage_date,
  w.wh_credits_used,
  d.total_credits_used,
  d.total_credits_billed,
  d.cloud_services_used,
  d.cloud_services_adjustment,
  (d.cloud_services_used + d.cloud_services_adjustment) AS cloud_services_billed
FROM all_compute_daily d
LEFT JOIN wh_daily w
  ON w.usage_date = d.usage_date
ORDER BY 1 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Treating `WAREHOUSE_METERING_HISTORY.CREDITS_USED` as “billed” | Overstates costs; breaks invoice reconciliation; can mis-rank optimization targets | Use `METERING_DAILY_HISTORY.CREDITS_BILLED` for billed; explain cloud services adjustment in UI. |
| Misalignment between hourly and daily grains | Confusing comparisons; apparent deltas | Use day-level aggregates when comparing; document that billed is daily. |
| ACCOUNT_USAGE ↔ ORG_USAGE reconciliation without UTC session | False mismatches between views | Enforce `ALTER SESSION SET TIMEZONE = UTC` in the app’s reconciliation stored procedures. |
| Latency differences (ACCOUNT_USAGE vs ORG_USAGE) | Recent days may “not match yet” | Display freshness metadata; avoid alerting on the newest N hours/days. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
5. https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Add a small “cost semantics” doc page in the Native App: **consumed vs billed**, and how cloud services adjustment works.
- Extend the daily fact view to include currency by joining ORG_USAGE.`USAGE_IN_CURRENCY_DAILY` (org-level) where available (note: separate latency/permissions).
- Decide how the app should present “warehouse-level cost” when billed is only daily + cross-service (recommend: warehouse-level is consumption telemetry; billed is account/org-level unless user opts into attribution modeling).
