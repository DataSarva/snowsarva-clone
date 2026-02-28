# Research: FinOps - 2026-02-28

**Time:** 00:32 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake documents that **cloud services credits are not always billed**: usage for cloud services is charged only if the *daily* cloud services consumption exceeds **10% of the daily virtual warehouse usage**; to see billed credits after this adjustment, query `METERING_DAILY_HISTORY`. (Snowflake docs) [1]
2. Snowflake documents that most `ACCOUNT_USAGE` / `ORGANIZATION_USAGE` cost views are expressed in **credits**, and that currency analysis should use `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, which converts usage to cost using the **daily price of a credit**. (Snowflake docs) [1]
3. `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` is a **billing-reconciliation-oriented** dataset: `USAGE_TYPE` is backward-compat and Snowflake recommends using `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT` for reconciliation; the view can have **up to 72 hours latency** and can change until month close due to adjustments. (Snowflake docs) [2]
4. Snowflake’s billing reconciliation guidance uses `USAGE_IN_CURRENCY_DAILY` to reconcile **contract consumption in currency** (not credits), and explicitly filters out `balance_source = 'overage'` when reconciling contract “Total Consumed”. (Snowflake docs) [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Use for **billed** credits after cloud services adjustment; daily grain. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (`CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_USED`); may not include billing adjustments. (Adjustment is documented to be applied daily via `METERING_DAILY_HISTORY`.) [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Org-level analog; daily metering with adjustment semantics; allows multi-account rollups. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily usage in both units (credits/TB/etc depending on `RATING_TYPE`) and currency; includes `BALANCE_SOURCE`, `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`; can change until month close. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY` | View | `ORG_USAGE` | Used to reconcile remaining contract balance. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Billing-vs-consumption reconciler module (daily):** add a “Billing reconciliation” panel that compares (a) credits from `METERING_DAILY_HISTORY` vs (b) cost lines from `USAGE_IN_CURRENCY_DAILY` grouped by `SERVICE_TYPE` / `BILLING_TYPE`, and flags days with large deltas (e.g., adjustments, cloud services threshold impacts). Sources: [1][2][3]
2. **Cost in currency rollup view (org):** materialize a canonical `FACT_DAILY_COST_CURRENCY` view/table built from `USAGE_IN_CURRENCY_DAILY` with strict filters (`billing_type='consumption'`, `is_adjustment=false/true` separated) so the app can show “true bill” vs “usage” consistently. Sources: [2][3]
3. **Data freshness & month-close stability guardrail:** implement a UX banner and data-quality checks: if `USAGE_IN_CURRENCY_DAILY` data is <72h old or within an open month, label as “preliminary”; if values change day-over-day for same `USAGE_DATE`, record an “adjustment event”. Sources: [2]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Daily currency rollup + compare against billed credits

```sql
-- Goal: produce a daily dataset that:
--  (1) rolls up currency spend by SERVICE_TYPE
--  (2) rolls up billed credits (after cloud services adjustment)
--  (3) highlights mismatches between "credits-consumption" views and currency billing views
--
-- Notes from docs:
--  - USAGE_IN_CURRENCY_DAILY is org-level, daily, can lag up to 72h and can change until month close.
--  - Cloud services billing adjustment is reflected in METERING_DAILY_HISTORY.

WITH currency AS (
  SELECT
    usage_date,
    account_locator,
    region,
    currency,
    billing_type,
    rating_type,
    service_type,
    is_adjustment,
    balance_source,
    SUM(usage)              AS units,
    SUM(usage_in_currency)  AS usage_in_currency
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE TRUE
    AND usage_date >= DATEADD('day', -35, CURRENT_DATE())
    AND billing_type IN ('consumption', 'rebate', 'support_credit', 'priority support', 'vps_deployment_fee')
  GROUP BY ALL
),

billed_credits AS (
  SELECT
    usage_date,
    -- org-level daily metering is the easiest way to match the org-level currency view
    SUM(credits_used) AS credits_used_total,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_adjustment_cloud_services) AS credits_adjustment_cloud_services,
    SUM(credits_used + credits_adjustment_cloud_services) AS credits_billed_after_adjustment
  FROM snowflake.organization_usage.metering_daily_history
  WHERE TRUE
    AND usage_date >= DATEADD('day', -35, CURRENT_DATE())
  GROUP BY 1
)

SELECT
  c.usage_date,
  c.currency,
  c.billing_type,
  c.rating_type,
  c.service_type,
  c.is_adjustment,
  SUM(c.usage_in_currency) AS spend_in_currency,
  b.credits_billed_after_adjustment,
  b.credits_used_total,
  b.credits_adjustment_cloud_services
FROM currency c
LEFT JOIN billed_credits b
  ON b.usage_date = c.usage_date
GROUP BY 1,2,3,4,5,6,8,9,10;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `USAGE_IN_CURRENCY_DAILY` is **org-only**; single-account customers may not have access / may not be in an org context. | Native app may need an account-only fallback for “currency” reporting. | Confirm which customer segments have `ORGANIZATION_USAGE` available and privileges needed. [2] |
| Until month close, currency values can change due to adjustments. | Dashboards may appear to “rewrite history” unless we capture revisions or label preliminary data. | Implement revision tracking: snapshot daily totals and diff. [2] |
| Cloud services “10% adjustment” means credits in warehouse metering may not equal billed credits. | Confusing deltas across app dashboards unless we standardize definitions (“consumed” vs “billed”). | Adopt consistent semantics: “consumed credits” vs “billed credits (post-adjustment)”. [1] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. https://docs.snowflake.com/en/user-guide/billing-reconcile
4. https://community.snowflake.com/s/article/Inconsistency-in-credit-usage-of-WAREHOUSE-METERING-HISTORY-and-USAGE-IN-CURRENCY-DAILY-view

## Next Steps / Follow-ups

- Extract and summarize the Snowflake Community thread to see common root causes (e.g., cloud services adjustment, service_type semantics, month-close adjustments) and add concrete troubleshooting playbook.
- Decide on app-wide canonical definitions:
  - (a) “credits consumed” (raw)
  - (b) “credits billed” (after adjustments)
  - (c) “spend in currency” (billing view)
- Add a small “reconciliation” job (daily) that stores deltas and flags anomalies for operator review.
