# Research: FinOps - 2026-03-01

**Time:** 19:22 UTC  
**Topic:** Snowflake FinOps Cost Optimization (usage → billed credits → currency; Native App-friendly model)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credit usage per warehouse** for the last **365 days**, including `CREDITS_USED` and its split into compute vs cloud services; however, `CREDITS_USED` **does not include the cloud-services billing adjustment** and may exceed what is actually billed. To determine billed credits you should query `METERING_DAILY_HISTORY`. (Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`.)
2. `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` provides **daily credits used and credits billed** (including `CREDITS_ADJUSTMENT_CLOUD_SERVICES`) for an organization for the last **365 days**, with view latency up to **~2 hours**. (Source: Snowflake docs for `METERING_DAILY_HISTORY`.)
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily usage in currency** (e.g., `USAGE_IN_CURRENCY`) across service/rating/billing types, but has **high latency (up to 72 hours)** and data can change until month close; additionally, some customers (e.g., reseller contracts) cannot access it. (Source: Snowflake docs for `USAGE_IN_CURRENCY_DAILY`.)
4. For reconciling Account Usage views with Organization Usage views, Snowflake documents that you should set the session timezone to **UTC** when querying the Account Usage view(s). (Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY` usage notes.)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly warehouse credits (365 days). Latency up to 180 min (cloud services column up to 6h). `CREDITS_USED` may not match billed due to cloud-services adjustment. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | view | `ORG_USAGE` | Daily organization credits + `CREDITS_BILLED` (includes cloud-services adjustment). Latency up to 120 min. Retained 365 days. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | view | `ORG_USAGE` | Daily currency amounts with dimensions: `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`. Latency up to 72h; data mutable until month close; not available to some reseller-contract customers. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | `ACCOUNT_USAGE` | Per-query metadata including `WAREHOUSE_NAME`, `QUERY_TAG`, `CREDITS_USED_CLOUD_SERVICES` (not billed-adjusted). Useful for attribution (e.g., tags → teams/apps). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Billed credits scaler” daily table**: compute a daily multiplier `billed_credits / used_credits` from `ORG_USAGE.METERING_DAILY_HISTORY` and apply it to account-level warehouse usage to estimate billed credits per warehouse/day.
2. **“Effective $/credit” estimator**: derive an implied $/credit per day/account from `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` for `RATING_TYPE='compute'` and apply it downstream for cost estimation when contract pricing is opaque.
3. **Native App cost model contract**: ship a stable schema (tables + views) inside the app that normalizes (a) hourly warehouse usage, (b) daily billed credits, and (c) daily currency costs into an “attribution-ready” fact table keyed by `usage_date`, `account_locator`, `warehouse_name`, `query_tag`.

## Concrete Artifacts

### Artifact: SQL draft — Estimate daily cost per warehouse (used credits → billed credits → currency)

Goal: produce a daily per-warehouse cost estimate that is (a) warehouse-granular (from account usage), (b) reconciled to billed credits (org usage), and (c) optionally expressed in currency when available.

Assumptions are called out inline.

```sql
-- ESTIMATED_DAILY_WAREHOUSE_COST
--
-- Notes / assumptions:
-- 1) WAREHOUSE_METERING_HISTORY is hourly; we aggregate to day in UTC for reconciling with ORG_USAGE.
-- 2) Cloud-services billing adjustment exists only at daily/account level (ORG_USAGE.METERING_DAILY_HISTORY).
--    We allocate billed credits down to warehouses proportional to their daily used credits.
-- 3) Currency allocation is optional; USAGE_IN_CURRENCY_DAILY may be unavailable/late.
--
-- Session timezone alignment per Snowflake docs.
ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_daily_used AS (
  SELECT
    DATE_TRUNC('DAY', start_time)::DATE AS usage_date,
    warehouse_name,
    SUM(credits_used) AS credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
acct_daily_used AS (
  SELECT
    usage_date,
    SUM(credits_used) AS acct_credits_used
  FROM wh_daily_used
  GROUP BY 1
),
acct_daily_billed AS (
  -- ORG_USAGE has account-level context fields; we key on usage_date and (optionally) account locator/name.
  -- If you’re running this inside a single account context, you can filter to your account.
  SELECT
    usage_date,
    SUM(credits_used)      AS org_credits_used,
    SUM(credits_billed)    AS org_credits_billed
  FROM snowflake.organization_usage.metering_daily_history
  WHERE usage_date >= DATEADD('DAY', -30, CURRENT_DATE())
    AND service_type = 'WAREHOUSE_METERING'
  GROUP BY 1
),
compute_currency_daily AS (
  -- Optional: implied $/credit for compute usage.
  -- Use BILLING_TYPE/RATING_TYPE to isolate compute consumption.
  SELECT
    usage_date,
    SUM(IFF(rating_type = 'compute' AND billing_type = 'consumption', usage, 0)) AS compute_usage_credits,
    SUM(IFF(rating_type = 'compute' AND billing_type = 'consumption', usage_in_currency, 0)) AS compute_usage_currency
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('DAY', -30, CURRENT_DATE())
  GROUP BY 1
)
SELECT
  w.usage_date,
  w.warehouse_name,
  w.credits_used,
  -- Allocate billed credits proportionally
  w.credits_used * (b.org_credits_billed / NULLIF(b.org_credits_used, 0)) AS est_credits_billed,
  -- Estimate currency using implied $/credit when available
  (w.credits_used * (b.org_credits_billed / NULLIF(b.org_credits_used, 0)))
    * (c.compute_usage_currency / NULLIF(c.compute_usage_credits, 0))      AS est_cost_currency
FROM wh_daily_used w
JOIN acct_daily_used a
  ON a.usage_date = w.usage_date
LEFT JOIN acct_daily_billed b
  ON b.usage_date = w.usage_date
LEFT JOIN compute_currency_daily c
  ON c.usage_date = w.usage_date
ORDER BY 1 DESC, 2;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocating daily billed credits down to warehouses proportional to used credits assumes the cloud-services adjustment should be distributed evenly by compute usage. | Per-warehouse billed estimates may be biased (e.g., some warehouses drive more cloud services). | Compare against per-query `credits_used_cloud_services` in `ACCOUNT_USAGE.QUERY_HISTORY` and warehouse-level cloud-services patterns (still not billed-adjusted, but directional). |
| `USAGE_IN_CURRENCY_DAILY` access may be restricted (e.g., reseller contracts) and has high latency (up to 72h). | Currency features may be delayed/unavailable, reducing “real $” accuracy. | Feature-flag currency layer; fall back to “credits-only” attribution. Detect view availability and freshness. |
| Timezone mismatch between account-usage timestamps and org-usage dates. | Reconciliation errors (off by a day) and user distrust. | Enforce `ALTER SESSION SET TIMEZONE=UTC` (documented by Snowflake) and test reconciliation with known days. |
| ORG_USAGE views are organization-level and require appropriate privileges. | Native App may not be able to rely on them by default. | Identify minimum grants; add setup checks + clear UX guidance; provide account-only mode using `ACCOUNT_USAGE`/`INFORMATION_SCHEMA` when org views unavailable. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
4. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Validate the `SERVICE_TYPE` filtering logic for `ORG_USAGE.METERING_DAILY_HISTORY` (e.g., how to incorporate `CLOUD_SERVICES` vs `WAREHOUSE_METERING` and other compute-related services) and decide what “compute cost” means for the app’s first iteration.
- Draft a **Native App setup-check spec**: detect which of these views exist/are queryable and compute a “freshness score” (e.g., hourly credits fresh, currency stale) for UI messaging.
- Add a second attribution dimension: `QUERY_TAG`-based allocation (from `ACCOUNT_USAGE.QUERY_HISTORY`) to map warehouse/day costs onto teams/apps.
