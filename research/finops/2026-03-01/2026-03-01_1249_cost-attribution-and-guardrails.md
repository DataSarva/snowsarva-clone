# Research: FinOps - 2026-03-01

**Time:** 12:49 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for compute cost attribution is: **object tags** to map resources/users to cost centers, and **query tags** to map per-query usage when a shared app runs queries on behalf of multiple cost centers. (Snowflake “Attributing cost”) [1]
2. In a single account, cost attribution by tag is typically built by joining **SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES** to cost/usage views like **WAREHOUSE_METERING_HISTORY** (warehouse credits) and **QUERY_ATTRIBUTION_HISTORY** (per-query attributed credits). (Snowflake “Attributing cost”) [1]
3. **QUERY_ATTRIBUTION_HISTORY** provides compute cost per query as credits attributed to that query **excluding warehouse idle time**; Snowflake documents that idle time is not part of per-query cost attribution. (Snowflake “Attributing cost”) [1]
4. **WAREHOUSE_METERING_HISTORY** (ACCOUNT_USAGE) is an hourly warehouse credit usage view; `CREDITS_USED` is the sum of `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES` and is **pre-adjustment** for cloud services. Snowflake recommends using **METERING_DAILY_HISTORY** to determine “actually billed” credits. (Snowflake WAREHOUSE_METERING_HISTORY view) [4]
5. Resource monitors can **monitor and optionally suspend** warehouses once credit thresholds are hit, but they **do not track spending for serverless features and AI services** (Snowflake says use a budget for those). (Snowflake “Working with resource monitors”) [3]
6. Organization-level $ cost data is available via **SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY**, which returns daily usage in credits/TB/etc plus **USAGE_IN_CURRENCY** and includes columns needed for billing reconciliation (billing_type/rating_type/service_type). (Snowflake USAGE_IN_CURRENCY_DAILY) [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Tag assignments for objects (warehouses, users, etc.) used for cost attribution joins. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse credits; has `CREDITS_USED_COMPUTE`, `...CLOUD_SERVICES`, `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 3h (6h for cloud services). [4] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query attributed compute credits; documented as excluding idle time and other cost classes. [1] *(Org-wide equivalent does not exist.)* |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | view | ORG_USAGE | Daily usage and cost in currency across org; latency up to 72h; not available for reseller contracts. [2] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | view | ACCOUNT_USAGE | Mentioned by Snowflake for billed credits reconciliation vs `CREDITS_USED` in WAREHOUSE_METERING_HISTORY. [4] *(Not extracted today; referenced by WAREHOUSE_METERING_HISTORY docs.)* |
| RESOURCE MONITOR objects (CREATE/ALTER/SHOW) | object | SQL DDL + metadata | Monitor credit usage for warehouses, notify/suspend actions; cannot cover serverless/AI. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Effective $/credit per day” engine**: derive daily effective $/credit from ORG_USAGE.USAGE_IN_CURRENCY_DAILY (filtering to compute/warehouse metering) and apply it to account-level hourly/daily warehouse credits to estimate **dollar spend by tag** even when contract pricing varies.
2. **Tag coverage & hygiene report**: show % of credits in the last 30 days that are attributable to a `cost_center` warehouse tag vs “untagged”; alert on untagged drift (Snowflake examples explicitly bucket untagged). [1]
3. **Guardrails advisor**: recommend resource monitor configs (notify/suspend thresholds) per top warehouses based on trailing 30-day usage patterns, with an explicit warning that monitors only cover warehouses (not serverless/AI). [3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily $ cost by warehouse tag (cost_center)

Goal: produce a daily table of **estimated USD (or org currency) warehouse compute spend per cost center**.

Approach:
- Compute daily warehouse credits per warehouse from ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY.
- Join tags (warehouse → cost_center) via ACCOUNT_USAGE.TAG_REFERENCES.
- Estimate $/credit per account+day from ORG_USAGE.USAGE_IN_CURRENCY_DAILY for warehouse metering compute.
  - Note: this yields an *effective* rate and is best-effort; month-close adjustments can change values. [2]

```sql
-- Assumptions/notes:
-- 1) Requires ORGADMIN (or org account) access for ORGANIZATION_USAGE. [2]
-- 2) Uses org currency and effective $/credit from USAGE_IN_CURRENCY_DAILY.
-- 3) Filters to SERVICE_TYPE='WAREHOUSE_METERING' + RATING_TYPE='compute' (validate exact values in your account).
-- 4) Tag location assumes COST_MANAGEMENT.TAGS.COST_CENTER as in Snowflake docs; adjust tag_database/tag_schema/name.
-- 5) ACCOUNT_USAGE latency: WH metering up to 3h (6h for cloud services). [4]

ALTER SESSION SET TIMEZONE = 'UTC'; -- required if reconciling account vs org usage timelines. [4]

WITH wh_credits_daily AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -45, CURRENT_TIMESTAMP())
    AND warehouse_id > 0
  GROUP BY 1, 2, 3
),

warehouse_cost_center AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
    AND tag_name = 'COST_CENTER'
    AND tag_database = 'COST_MANAGEMENT'
    AND tag_schema = 'TAGS'
),

-- Effective price per credit for warehouse metering compute (org-level)
rate_daily AS (
  SELECT
    usage_date,
    account_locator,
    region,
    currency,
    SUM(usage) AS credits,
    SUM(usage_in_currency) AS cost_in_currency,
    IFF(SUM(usage) = 0, NULL, SUM(usage_in_currency) / SUM(usage)) AS currency_per_credit
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -45, CURRENT_DATE())
    AND LOWER(rating_type) = 'compute'
    AND UPPER(service_type) = 'WAREHOUSE_METERING'
    AND LOWER(billing_type) = 'consumption'
    AND is_adjustment = FALSE
  GROUP BY 1, 2, 3, 4
)

SELECT
  w.usage_date,
  r.currency,
  COALESCE(t.cost_center, 'untagged') AS cost_center,
  SUM(w.credits_used_compute) AS credits_used_compute,
  AVG(r.currency_per_credit) AS est_currency_per_credit,
  SUM(w.credits_used_compute) * AVG(r.currency_per_credit) AS est_cost_in_currency
FROM wh_credits_daily w
LEFT JOIN warehouse_cost_center t
  ON w.warehouse_id = t.warehouse_id
-- NOTE: join keys for rate_daily depend on how you want to attribute across accounts.
-- If running inside a single account, you may need to hardcode your account_locator/region or parameterize.
JOIN rate_daily r
  ON w.usage_date = r.usage_date
GROUP BY 1, 2, 3
ORDER BY usage_date DESC, est_cost_in_currency DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE access is required to use USAGE_IN_CURRENCY_DAILY; not all accounts/users have it (ORGADMIN / org account requirements), and reseller contracts cannot access it. | Dollar-cost attribution may not be available for some customers; need credit-only fallback. | Check if `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` is queryable and not blocked by reseller note. [2] |
| The exact `SERVICE_TYPE` / `RATING_TYPE` values used for warehouse compute in USAGE_IN_CURRENCY_DAILY must match filters. | Mis-filtering could under/overcount $/credit. | Run exploratory query grouping by `service_type`, `rating_type` for last 7 days. [2] |
| Per-query attribution via QUERY_ATTRIBUTION_HISTORY excludes idle time and many cost classes (storage, transfer, serverless, AI tokens). | “Cost per query” features must be labeled compute-only and may not reconcile to invoice without additional modeling. | Keep UI copy explicit; optionally add idle-cost allocation from WAREHOUSE_METERING_HISTORY. [1][4] |
| Resource monitors only work for warehouses; cannot cap serverless/AI costs. | Guardrails might create false confidence if presented as “total budget controls”. | In-app guardrails must split “warehouse caps” vs “serverless/AI budgets”. [3] |
| Latency and month-close adjustments: ORG_USAGE can change until month close; ACCOUNT_USAGE has hour-level delays (3–6h). | Near-real-time dashboards can be temporarily wrong. | Show freshness timestamps; provide “month-close finalization” mode. [2][4] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY: https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. Snowflake Docs — Working with resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
4. Snowflake Docs — ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Pull Snowflake docs for **METERING_DAILY_HISTORY** to confirm billed-credit reconciliation mechanics and columns (needed for invoice-grade reconciliation). (Referenced from WAREHOUSE_METERING_HISTORY docs.) [4]
- Add a second artifact: “idle cost by warehouse + tag” using `(credits_used_compute - credits_attributed_compute_queries)` per warehouse (Snowflake provides an example query). [4]
- Product decision: decide whether our Native App supports **credit-only attribution** as default and gates **currency attribution** behind ORGADMIN availability.
