# Research: FinOps - 2026-03-02

**Time:** 12:38 UTC  
**Topic:** Snowflake FinOps Cost Optimization (ORG_USAGE cost intelligence + reconciliation patterns)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` returns **daily credit usage** by `SERVICE_TYPE` **per account within an organization**, with `USAGE_DATE` explicitly in **UTC** and up to **~120 minutes latency**, with **365 days** retention. [2]
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides the analogous daily credit usage at the **single-account scope**, and Snowflake notes you should set the session timezone to **UTC** when reconciling with Organization Usage views. [1]
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` returns **daily usage in currency** (and the underlying rated usage) at the organization scope, including `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT`, and Snowflake notes that data can change until **month close** and can have up to **72 hours latency**. [3]
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `CREDITS_USED_CLOUD_SERVICES` at the query level, and Snowflake explicitly notes that this value **does not include the cloud-services billing adjustment**, and you should use `METERING_DAILY_HISTORY` to determine what was actually billed. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Daily credits by `SERVICE_TYPE` + per-account dimensions (`ACCOUNT_LOCATOR`, `ACCOUNT_NAME`, `REGION`); `USAGE_DATE` is UTC; 365d retention. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits and cloud-services adjustment; reconcile with ORG_USAGE by setting session timezone to UTC. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily charges in currency with billing/rating dimensions and adjustments; latency up to 72h; values may change until month close. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level execution + cloud services credits (not billing-adjusted); join path for attribution. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide daily spend dashboard (credits + currency)**: build a canonical daily fact table keyed by (`org`, `account_locator`, `usage_date`, `service_type`) sourced from `ORG_USAGE.METERING_DAILY_HISTORY` + `ORG_USAGE.USAGE_IN_CURRENCY_DAILY`, explicitly modeling latency and month-close drift.
2. **Reconciliation guardrails**: automated checks that enforce `ALTER SESSION SET TIMEZONE = 'UTC'` (or equivalent) in the ingestion job and detect day-boundary mismatches between ORG_USAGE and ACCOUNT_USAGE aggregates.
3. **Attribution “bridge”**: use ORG_USAGE as the billed truth for daily totals, and allocate daily totals down to warehouses/queries (from ACCOUNT_USAGE) proportionally, while keeping a residual bucket for un-attributable service types.

## Concrete Artifacts

### SQL draft: Org-wide daily cost (credits + currency) by account + service_type

Goal: produce a daily table that can power “which accounts are costing what, and why” across an entire org.

Notes:
- This draft intentionally uses `ORG_USAGE` only, so it works across many accounts without needing per-account connections.
- If you later reconcile with `ACCOUNT_USAGE`, follow Snowflake’s guidance to set session timezone to UTC for comparability. [1]

```sql
-- Daily org usage: credits + currency
-- Assumes you have access to SNOWFLAKE.ORGANIZATION_USAGE

WITH credits AS (
  SELECT
    organization_name,
    account_locator,
    account_name,
    region,
    usage_date,              -- UTC per docs
    service_type,
    credits_used_compute,
    credits_used_cloud_services,
    credits_adjustment_cloud_services,
    credits_billed
  FROM snowflake.organization_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
),
charges AS (
  SELECT
    organization_name,
    account_locator,
    account_name,
    region,
    usage_date,              -- UTC per docs
    service_type,
    billing_type,
    rating_type,
    is_adjustment,
    currency,
    usage_in_currency
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
)
SELECT
  c.organization_name,
  c.account_locator,
  c.account_name,
  c.region,
  c.usage_date,
  c.service_type,
  c.credits_billed,

  -- Currency may include non-compute items depending on service_type / billing_type / rating_type.
  -- Keep billing_type/rating_type for drilldown.
  SUM(ch.usage_in_currency) AS usage_in_currency,
  ANY_VALUE(ch.currency)    AS currency,

  -- Helpful dimensional rollups for dashboards
  ARRAY_AGG(DISTINCT ch.billing_type) WITHIN GROUP (ORDER BY ch.billing_type) AS billing_types,
  ARRAY_AGG(DISTINCT ch.rating_type)  WITHIN GROUP (ORDER BY ch.rating_type)  AS rating_types,
  BOOLOR(ch.is_adjustment) AS has_adjustments
FROM credits c
LEFT JOIN charges ch
  ON ch.organization_name = c.organization_name
 AND ch.account_locator   = c.account_locator
 AND ch.usage_date        = c.usage_date
 AND ch.service_type      = c.service_type
GROUP BY
  c.organization_name,
  c.account_locator,
  c.account_name,
  c.region,
  c.usage_date,
  c.service_type,
  c.credits_billed
ORDER BY c.usage_date DESC, usage_in_currency DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Not all orgs can access `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` (e.g., reseller contracts). | Currency-based dashboards may be unavailable; must fall back to credits-only. | Confirm access in target org; Snowflake explicitly notes reseller customers cannot access this view. [3] |
| `USAGE_IN_CURRENCY_DAILY` can change until month close and has higher latency. | Dashboards can “move” for recent days; alerts may be noisy. | Implement data freshness windows + month-close reconciliation job. [3] |
| Joining credits ↔ currency by `(usage_date, service_type, account)` assumes consistent `service_type` taxonomy between views. | Mismatched joins create “missing currency” or “missing credits” rows. | Add an audit query listing unmatched keys and monitor over time; treat as expected drift if small. |
| Attribution from daily billed totals down to queries/warehouses is not directly available from ORG_USAGE alone. | Need multi-step allocation logic; can create residuals. | Use per-account `ACCOUNT_USAGE.QUERY_HISTORY` as an attribution source and reconcile back to billed totals. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
2. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
4. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Validate joinability between `ORG_USAGE.METERING_DAILY_HISTORY` and `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` in a real org (row counts + missing-key audit).
- Decide “billing truth” hierarchy for the app: currency view (when available) vs credits-only.
- Draft a small ADR for the app’s canonical cost fact table + freshness semantics (latency windows, month-close backfill policy).
