# Research: FinOps - 2026-03-04

**Time:** 01:18 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Organization-wide *effective rates* (discounted contract rates) for usage-in-currency calculations are available via `SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY`, including `EFFECTIVE_RATE`, `SERVICE_TYPE`, `RATING_TYPE`, `BILLING_TYPE`, and an `IS_ADJUSTMENT` flag; values may change until month close and lag by up to ~24h. (RATE_SHEET_DAILY)  
2. For organization-wide cost attribution in *currency*, Snowflake recommends querying organization-level usage/cost views (e.g., `USAGE_IN_CURRENCY_DAILY`) and filtering by `service_type` for feature slices; many cost/usage views provide credits (not currency) and currency conversion relies on daily credit price. (Exploring compute cost)  
3. Fine-grained *per-query* compute attribution is available via `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`, but Snowflake explicitly states there is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`; any per-query analysis must be performed account-by-account. (Attributing cost)
4. Warehouse and user tagging is the core mechanism Snowflake documents for showback/chargeback; the documented approach is: (a) object tags for resources/users and (b) query tags for shared applications issuing queries on behalf of multiple cost centers. (Attributing cost)
5. Cloud services credits are not always billed; Snowflake notes billing only occurs when daily cloud services consumption exceeds 10% of daily warehouse usage, and directs users to `METERING_DAILY_HISTORY` to determine billed compute credits. (Exploring compute cost)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY` | view | ORG_USAGE | Effective rates in org currency; includes `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`; lag up to 24h; mutable until month close; not available via resellers. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | view | ORG_USAGE | Mentioned as the org-level path to compute *currency* costs; converts credits → currency using daily credit price. (Details not extracted in this run.) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | ACCOUNT_USAGE | Used to compute *billed* cloud services after the 10% rule adjustment. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | ACCOUNT_USAGE | Hourly warehouse credits (compute + cloud services components); used for warehouse-level attribution. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | ACCOUNT_USAGE | Tag assignments for objects (warehouses/users/etc.) within an account. |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | view | ORG_USAGE | Available only in the *organization account*; used for cross-account tagging joins. (Attributing cost)
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | ACCOUNT_USAGE | Per-query credits attributed to compute; no org-wide equivalent; excludes warehouse idle time; excludes storage/transfer/serverless/etc. (Attributing cost)

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Rate-aware cost explorer:** In the org account, build a “Rate Sheet Explorer” page that shows `EFFECTIVE_RATE` trends by `SERVICE_TYPE`/`RATING_TYPE` over time (including `IS_ADJUSTMENT`) to explain month-close drift and to validate currency conversions.
2. **Chargeback model with explicit limits:** Implement a first-pass org-wide chargeback that supports only *dedicated resources* (e.g., warehouses tagged to a single cost center) because org-wide per-query attribution is not possible (`QUERY_ATTRIBUTION_HISTORY` is account-only).
3. **Billed-vs-consumed compute clarity:** Add a “Billed Cloud Services” widget that uses `ACCOUNT_USAGE.METERING_DAILY_HISTORY` to show where cloud services credits were actually billed vs rebated by the 10% rule.

## Concrete Artifacts

### SQL draft: org-level warehouse cost by cost_center tag (credits + optional currency join)

This is a practical “showback” query for the **organization account** that:
- attributes warehouse credits to a cost center via warehouse tags (works best when warehouses are dedicated),
- keeps untagged spend visible,
- is designed to optionally join in rates for currency conversion.

```sql
/*
Goal: Organization-wide warehouse usage attributed to COST_CENTER tag.
Prereqs:
  - run in the ORG (organization) account
  - warehouse tags replicated and visible via ORG_USAGE.TAG_REFERENCES
  - COST_MANAGEMENT.TAGS.COST_CENTER exists (or adjust tag_database/tag_schema)

Notes:
  - This query attributes WAREHOUSE_METERING_HISTORY credits (not per-query credits).
  - Currency conversion can be layered by joining to ORG_USAGE.RATE_SHEET_DAILY (effective rates).
*/

WITH wh_credits AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_date,
    account_locator,
    account_name,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS credits_compute
  FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND start_time <  CURRENT_TIMESTAMP()
  GROUP BY 1,2,3,4,5
),
wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_database = 'COST_MANAGEMENT'
    AND tag_schema   = 'TAGS'
    AND tag_name     = 'COST_CENTER'
),
rate AS (
  /*
  RATE_SHEET_DAILY is per account/date and includes service_type/rating_type.
  Exact join keys to compute-warehouse may vary by contract setup; keep this as a draft.
  */
  SELECT
    date AS usage_date,
    account_locator,
    /* Heuristic: compute warehouse credits priced as RATING_TYPE='compute'. */
    MAX(IFF(rating_type = 'compute' AND billing_type = 'consumption', effective_rate, NULL)) AS effective_rate_compute
  FROM SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
  WHERE date >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1,2
)
SELECT
  c.usage_date,
  c.account_name,
  COALESCE(t.cost_center, 'untagged') AS cost_center,
  SUM(c.credits_compute) AS credits_compute,
  /* Optional currency estimate: */
  SUM(c.credits_compute) * MAX(r.effective_rate_compute) AS est_cost_currency
FROM wh_credits c
LEFT JOIN wh_tags t
  ON c.warehouse_id = t.warehouse_id
LEFT JOIN rate r
  ON r.usage_date = c.usage_date
 AND r.account_locator = c.account_locator
GROUP BY 1,2,3
ORDER BY 1 DESC, est_cost_currency DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `RATE_SHEET_DAILY` join logic for “warehouse compute effective rate” may not be a single row per day/account. | Currency conversion could be wrong or double-counted. | Validate against `USAGE_IN_CURRENCY_DAILY` totals for the same day/account; ensure filters on `BILLING_TYPE`, `RATING_TYPE`, and possibly `SERVICE_TYPE` match Snowflake statement semantics. (RATE_SHEET_DAILY, Exploring compute cost) |
| Tag replication / visibility differs by org setup; ORG usage tagging requires org account. | Chargeback queries may fail or silently exclude tags in non-org accounts. | Confirm `ORGANIZATION_USAGE.TAG_REFERENCES` availability and required roles in org account. (Attributing cost) |
| Org-wide per-query cost attribution is not supported (no org-wide `QUERY_ATTRIBUTION_HISTORY`). | Cannot produce a single org-wide “top expensive queries” report without iterating accounts. | Must implement per-account pipelines or accept warehouse-level approximations. (Attributing cost) |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake Docs — RATE_SHEET_DAILY view (ORG_USAGE): https://docs.snowflake.com/en/sql-reference/organization-usage/rate_sheet_daily
4. Snowflake Docs — Cost & billing overview: https://docs.snowflake.com/en/guides-overview-cost

## Next Steps / Follow-ups

- Extract + review `USAGE_IN_CURRENCY_DAILY` reference page to pin down exact semantics and join keys (service_type/rating_type/billing_type) for consistent currency conversion.
- Decide on an MVP contract for chargeback: (a) dedicated warehouses only (org-wide), (b) per-query attribution per account (requires account iteration + permissions), or (c) hybrid.
- Prototype a native-app “Rates & Month Close Drift” explanation panel: show where `RATE_SHEET_DAILY` changes until month close and how that flows into dashboards.
