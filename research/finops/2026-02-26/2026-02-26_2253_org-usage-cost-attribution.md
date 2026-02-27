# Research: FinOps - 2026-02-26

**Time:** 22:53 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Org-level cost attribution + billing reconciliation primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake recommends using **object tags** (for resources/users) plus **query tags** (for per-query attribution when shared apps run on behalf of multiple cost centers) to implement showback/chargeback. [1]
2. Org-wide cost attribution has a hard limitation: **`QUERY_ATTRIBUTION_HISTORY` exists only in `SNOWFLAKE.ACCOUNT_USAGE` (single account) and has no organization-wide equivalent**, while `TAG_REFERENCES` in `ORGANIZATION_USAGE` is only available in the organization account. [1]
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily usage in both units (credits/TB/etc.) and currency**, with billing-oriented columns (`BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`) intended for reconciliation; data can lag up to **72 hours** and can change until month close. [2]
4. Snowflake’s billing usage statements can be reconciled with `ORGANIZATION_USAGE` billing views (e.g., `USAGE_IN_CURRENCY_DAILY`, `REMAINING_BALANCE_DAILY`). Prior to **2024-03-01**, rounding differences can produce small mismatches vs statements. [3]
5. `WAREHOUSE_METERING_HISTORY` provides hourly warehouse credit usage; when used for compute-cost exploration, Snowflake notes that **cloud services credits consumed are not always billed** (billed only if daily cloud services usage exceeds 10% of daily warehouse usage), and the billed amount can be derived from `METERING_DAILY_HISTORY`. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Tag ↔ object mapping for account-level attribution. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; joinable to tag references by `warehouse_id` / `object_id` for dedicated-warehouse showback. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query attributed credits (excludes idle time and excludes several non-warehouse cost categories); *no org-wide equivalent*. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Hourly warehouse credits across accounts; usable for org-wide dedicated-warehouse showback. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | ORG_USAGE | Only available in org account; needed for org-wide tagging joins. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily usage + currency (credits/TB/etc). Use billing-oriented columns for statement reconciliation. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY` | View | ORG_USAGE | Used for contract remaining balance reconciliation. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Can determine billed cloud services credits (credits used + adjustment). [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-level showback in currency by tag (dedicated resources):** Build a daily job/view that attributes `USAGE_IN_CURRENCY_DAILY` warehouse spend (`SERVICE_TYPE='WAREHOUSE_METERING'`) to `cost_center` tag values using `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` + `ORGANIZATION_USAGE.TAG_REFERENCES`. This covers multi-account organizations without needing per-query attribution.
2. **“Attribution coverage” dashboard:** For each account (and org account), report the share of warehouse credits/currency that are **untagged** (via `COALESCE(tag_value,'untagged')`) so platform teams can drive tagging hygiene. Snowflake explicitly shows this pattern in their sample SQL. [1]
3. **Statement reconciliation module:** Add a small “billing reconciliation” page that runs the documented reconciliation queries against `USAGE_IN_CURRENCY_DAILY` and `REMAINING_BALANCE_DAILY` to validate your FinOps model against the usage statement. [3]

## Concrete Artifacts

### Org-wide daily warehouse showback in currency by `cost_center` (dedicated warehouses)

Goal: Allocate daily warehouse *currency spend* to tag values (works across accounts, but only for resources attributable directly via warehouse tags).

```sql
-- Org-level: attribute WAREHOUSE_METERING spend to warehouse tag values.
-- Requires: org account access to ORGANIZATION_USAGE + TAG_REFERENCES.
-- Inputs:
--   * ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY (hourly credits by warehouse)
--   * ORGANIZATION_USAGE.TAG_REFERENCES (warehouse tags)
--   * ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY (daily $ for warehouse metering)
--
-- Strategy:
--  1) Aggregate hourly warehouse credits to (usage_date, account, warehouse_id)
--  2) Join warehouse tags to get tag_value (e.g., cost_center)
--  3) Convert credits -> currency by allocating the daily account-level warehouse $ proportionally

WITH wh_credits_by_day AS (
  SELECT
    TO_DATE(wmh.start_time)                              AS usage_date,
    wmh.account_locator,
    wmh.region,
    wmh.warehouse_id,
    SUM(wmh.credits_used_compute)                        AS credits_used_compute
  FROM snowflake.organization_usage.warehouse_metering_history wmh
  WHERE wmh.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3,4
),

wh_tagged AS (
  SELECT
    c.usage_date,
    c.account_locator,
    c.region,
    tr.tag_name,
    COALESCE(tr.tag_value, 'untagged')                   AS tag_value,
    c.credits_used_compute
  FROM wh_credits_by_day c
  LEFT JOIN snowflake.organization_usage.tag_references tr
    ON tr.domain = 'WAREHOUSE'
   AND tr.object_id = c.warehouse_id
   -- Optional hardening: ensure you only use the intended tag database/schema
   -- AND tr.tag_database = 'COST_MANAGEMENT'
   -- AND tr.tag_schema   = 'TAGS'
  WHERE (tr.tag_name = 'COST_CENTER' OR tr.tag_name IS NULL)
),

acct_wh_spend AS (
  SELECT
    usage_date,
    account_locator,
    region,
    SUM(usage_in_currency)                               AS warehouse_usage_in_currency
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE 1=1
    AND rating_type  = 'compute'
    AND service_type = 'WAREHOUSE_METERING'
    AND usage_date >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1,2,3
),

acct_total_credits AS (
  SELECT
    usage_date,
    account_locator,
    region,
    SUM(credits_used_compute)                            AS total_credits_used_compute
  FROM wh_tagged
  GROUP BY 1,2,3
)

SELECT
  t.usage_date,
  t.account_locator,
  t.region,
  t.tag_value,
  SUM(t.credits_used_compute)                                                AS credits_used_compute,
  -- allocate the daily $ proportionally by credits
  SUM(t.credits_used_compute) / NULLIF(MAX(tc.total_credits_used_compute),0)
    * MAX(s.warehouse_usage_in_currency)                                      AS usage_in_currency_allocated
FROM wh_tagged t
JOIN acct_total_credits tc
  ON tc.usage_date = t.usage_date
 AND tc.account_locator = t.account_locator
 AND tc.region = t.region
JOIN acct_wh_spend s
  ON s.usage_date = t.usage_date
 AND s.account_locator = t.account_locator
 AND s.region = t.region
GROUP BY 1,2,3,4
ORDER BY usage_in_currency_allocated DESC;
```

Notes:
- This design uses **currency spend from `USAGE_IN_CURRENCY_DAILY`** (billing-friendly) and allocates it across tag values by **credit share** from `WAREHOUSE_METERING_HISTORY`.
- This is intentionally scoped to **warehouse metering**. Per-query allocation across the org is blocked by the lack of an org-wide `QUERY_ATTRIBUTION_HISTORY`. [1]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `USAGE_IN_CURRENCY_DAILY` is only accessible to some customers/roles (e.g., ORGADMIN) and is unavailable in some cases (e.g., reseller contracts). | Native app may need a “credits-only mode” fallback or require org account privileges. | Confirm access model in target customers; check org account privileges + contract type. [2][3] |
| Using proportional allocation (credits share) assumes daily warehouse $ in `USAGE_IN_CURRENCY_DAILY` maps cleanly to summed `credits_used_compute` from `WAREHOUSE_METERING_HISTORY`. | If daily $ includes adjustments or non-credit components, allocation may drift. | Compare daily totals to statements; use `IS_ADJUSTMENT` / billing columns to filter as needed. [2][3] |
| Tag naming/casing conventions (`COST_CENTER` vs `cost_center`) vary. | Attribution joins may miss tags → false “untagged”. | Standardize tag definitions and enforce allowed values; validate with sample queries from Snowflake docs. [1] |
| Org-wide attribution for shared warehouses at per-user/per-query granularity is not possible with current views alone. | Limits app feature set (org-level per-query showback). | Document clearly; for shared warehouses, run account-scoped pipelines using `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`. [1] |

## Links & Citations

1. Snowflake Docs — *Attributing cost* (tags + query tags, and limitations around `QUERY_ATTRIBUTION_HISTORY` and org-level tagging): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` reference (billing-oriented columns, latency, adjustments): https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. Snowflake Docs — *Reconcile a billing usage statement* (queries against org billing views, rounding notes pre-2024-03-01): https://docs.snowflake.com/en/user-guide/billing-reconcile
4. Snowflake Docs — *Exploring compute cost* (cloud services billed-vs-consumed note; `METERING_DAILY_HISTORY`): https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Pull + study `ORGANIZATION_USAGE.RATE_SHEET_DAILY` and behavior change notes around billing views to see if it’s better to compute currency locally (credits × effective rate) vs relying on `USAGE_IN_CURRENCY_DAILY`.
- Extend the artifact into two modes:
  - **Org mode (warehouse-tag-based)**: multi-account showback for dedicated resources.
  - **Account mode (query-attribution-based)**: per-user/per-query allocation for shared resources (including idle-time allocation patterns shown in docs). [1]
- Define a canonical “Cost Attribution Dimension Set” for the Native App (`cost_center`, `env`, `app`, `owner`) and ship a tagging coverage report first.
