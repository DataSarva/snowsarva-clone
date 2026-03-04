# Research: FinOps - 2026-03-04

**Time:** 20:28 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**; the `CREDITS_USED` fields in this view **may exceed billed credits** because they do not incorporate the cloud-services billing adjustment; Snowflake points to `METERING_DAILY_HISTORY` for billed credits. [^acc_wh_mh]
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits used and **credits billed**, including `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative adjustment) and `CREDITS_BILLED`; latency is up to ~180 minutes and Snowflake notes the “set timezone to UTC” requirement when reconciling to organization usage. [^acc_mdh]
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily usage in credits / TB and in currency** across the org and includes metadata to reconcile billing (e.g., `BALANCE_SOURCE`, `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`); it has **up to 72 hours latency**, data can change until month close, and some reseller contracts cannot access this view. [^org_uicd]
4. `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credits across **all accounts in the organization** for last 365 days; latency may be up to 24 hours; its `CREDITS_USED` also does not incorporate the cloud-services billing adjustment and points to org `METERING_DAILY_HISTORY`. [^org_wh_mh]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse usage (credits) by warehouse; `CREDITS_USED` ≠ billed credits; latency up to ~3h (cloud services up to ~6h). [^acc_wh_mh] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily usage and billed credits; includes cloud services adjustment; use for reconciliation to billed credits. [^acc_mdh] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily usage across org; includes `USAGE_IN_CURRENCY` and billing metadata; can shift until month close. [^org_uicd] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Hourly warehouse usage across org; latency up to 24h. [^org_wh_mh] |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | ORG_USAGE | Daily credits billed / used across org; includes cloud-services adjustment; latency up to 2h. [^org_mdh] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org spend & anomaly monitor (currency-native):** Build a daily org-level spend cube from `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, with breakdowns by `ACCOUNT_NAME`, `REGION`, `SERVICE_LEVEL`, `SERVICE_TYPE`, `RATING_TYPE`, `BALANCE_SOURCE`, and `IS_ADJUSTMENT`, and implement rolling z-score / EWMA anomaly alerts.
2. **Cross-account warehouse metering rollup:** Use `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` to compute top warehouses across the org by hourly/daily credits, then drill into account-local details (tags, query attribution) by linking via `ACCOUNT_LOCATOR` / `ACCOUNT_NAME` to in-account datasets.
3. **Reconciliation report:** Add an “explains-the-bill” page that reconciles (a) sum of hourly warehouse credits (metering history) → (b) daily billed credits (metering daily) → (c) daily currency charges (usage-in-currency), explicitly documenting differences from cloud-services adjustment + non-warehouse service types.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Org-level daily warehouse charge, allocated to warehouses (heuristic)

Goal: produce an **estimated** `USAGE_IN_CURRENCY` per warehouse per day for org-wide reporting.

Important constraints:
- Snowflake exposes **currency** at the org/day/service_type level (`USAGE_IN_CURRENCY_DAILY`), but it does not natively provide **warehouse-level currency**.
- This draft allocates org-day warehouse charges to warehouses **proportionally by metered credits** from org `WAREHOUSE_METERING_HISTORY`.

```sql
-- Heuristic allocation of org-level warehouse charges ($) down to warehouses.
-- Assumption: SERVICE_TYPE='WAREHOUSE_METERING' in USAGE_IN_CURRENCY_DAILY represents
-- the same cost pool as WAREHOUSE_METERING_HISTORY credits for that org-day.

ALTER SESSION SET TIMEZONE = UTC;

WITH org_day_wh_credits AS (
  SELECT
    DATE_TRUNC('DAY', start_time)::DATE AS usage_date,
    organization_name,
    account_name,
    account_locator,
    region,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_used) AS credits_used_total
  FROM snowflake.organization_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3,4,5,6,7
),
org_day_wh_totals AS (
  SELECT
    usage_date,
    organization_name,
    SUM(credits_used_total) AS org_credits_total
  FROM org_day_wh_credits
  GROUP BY 1,2
),
org_day_wh_currency AS (
  SELECT
    usage_date,
    organization_name,
    currency,
    -- total org charge for warehouses that day
    SUM(usage_in_currency) AS org_wh_charge
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
    AND service_type = 'WAREHOUSE_METERING'
    AND is_adjustment = FALSE
  GROUP BY 1,2,3
)
SELECT
  c.usage_date,
  c.organization_name,
  c.account_name,
  c.account_locator,
  c.region,
  c.warehouse_id,
  c.warehouse_name,
  cur.currency,
  c.credits_used_total,
  tot.org_credits_total,
  cur.org_wh_charge,
  IFF(tot.org_credits_total = 0, NULL,
      cur.org_wh_charge * (c.credits_used_total / tot.org_credits_total))
    AS est_wh_charge_in_currency
FROM org_day_wh_credits c
JOIN org_day_wh_totals tot
  ON tot.usage_date = c.usage_date
 AND tot.organization_name = c.organization_name
JOIN org_day_wh_currency cur
  ON cur.usage_date = c.usage_date
 AND cur.organization_name = c.organization_name
ORDER BY 1 DESC, est_wh_charge_in_currency DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocating `USAGE_IN_CURRENCY_DAILY` (`SERVICE_TYPE='WAREHOUSE_METERING'`) down to warehouses proportionally by `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is an approximation; rate cards/discounts and adjustments may not map cleanly to metered credits. | Misstated per-warehouse $ values; good for rankings but not invoicing. | Reconcile totals: allocated sum per day must equal org warehouse charge; compare vs account-level billed credits where possible. |
| `USAGE_IN_CURRENCY_DAILY` can change until month close and has up to 72h latency. | Dashboards can “move” for recent days. | Show freshness + “preliminary” banner for current month; store snapshots if needed. [^org_uicd] |
| Org vs account usage reconciliation requires session timezone set to UTC. | Off-by-one-day errors in joins between org and account datasets. | Always `ALTER SESSION SET TIMEZONE = UTC;` in reconciliation jobs. [^acc_wh_mh][^acc_mdh] |
| Reseller customers may not have access to org usage currency views. | Feature unavailable in some deployments. | Detect missing privileges and fall back to credits-only reporting. [^org_uicd] |

## Links & Citations

[^acc_wh_mh]: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
[^acc_mdh]: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
[^org_uicd]: https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
[^org_wh_mh]: https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history
[^org_mdh]: https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history

## Next Steps / Follow-ups

- Confirm the exact set of `SERVICE_TYPE` values to include for “warehouse spend” in `USAGE_IN_CURRENCY_DAILY` in real customer data (e.g., `WAREHOUSE_METERING_READER` handling).
- Extend allocation to **accounts** first (org-day → account-day), then to **warehouses**, to make drilldowns more intuitive and to support accounts with missing warehouse history data.
- Add a “freshness model” in the app: expected latency per view (2h/3h/24h/72h) and a backfill window for month-close adjustments.
