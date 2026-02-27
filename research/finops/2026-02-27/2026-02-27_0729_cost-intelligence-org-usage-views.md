# Research: FinOps - 2026-02-27

**Time:** 07:29 UTC  
**Topic:** Snowflake FinOps Cost Optimization (org-level cost intelligence primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake cost/usage analytics can be built either from Snowsight cost management pages **or** by querying the shared `SNOWFLAKE` database’s `ACCOUNT_USAGE` and `ORGANIZATION_USAGE` schemas. `ORGANIZATION_USAGE` provides cost information across all accounts in an organization; `ACCOUNT_USAGE` provides similar information for a single account.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-overall
2. The org-level `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` view returns daily usage plus **usage in currency**, and includes billing-reconciliation metadata columns such as `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT`. Latency can be **up to 72 hours**, and daily data can change until month close due to adjustments/amendments/transfers.  
   Source: https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. The org-level `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` view returns daily credits by account (including compute, cloud services, and any cloud-services adjustment) with retention of **365 days** and latency up to **~120 minutes**.  
   Source: https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
4. The `ORGANIZATION_USAGE` schema is available in the organization account and in ORGADMIN-enabled accounts; access is controlled via Snowflake **application roles / database roles** (e.g., docs highlight roles like `ORG_USAGE_ADMIN` / `ORGANIZATION_USAGE_VIEWER` and `ORGANIZATION_BILLING_VIEWER` for billing views).  
   Source: https://docs.snowflake.com/en/sql-reference/organization-usage

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Org-wide daily cost in currency; includes billing metadata (`BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`) for reconciliation; latency up to 72h; can change until month close; retained indefinitely. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | ORG_USAGE | Org-wide daily credits (compute + cloud services + adjustment) by account; latency up to ~2h; retained 365d. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Account-level daily credits by service type; docs note UTC timezone alignment needed when reconciling with ORG_USAGE views. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Used by Snowsight tiles (e.g., top warehouses by cost) for account-level drilldowns. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org daily cost ledger (currency + credits)**: materialize a daily “gold” table keyed by `(org, account_locator, usage_date, service_type)` by combining `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` (currency truth) with `ORG_USAGE.METERING_DAILY_HISTORY` (credit truth + service credit split). This becomes the backbone for budgeting, anomaly detection, and allocation.
2. **Latency-aware freshness + backfill controls**: implement “data freshness” logic explicitly: credits can be near-real-time (~2h) while currency is delayed (up to 72h and mutable until month close). Surface this in the app UI and ensure pipelines backfill the last N days continuously.
3. **Privilege/role readiness check**: in onboarding, run a SQL “capability probe” that verifies required roles to read `ORG_USAGE` vs `ACCOUNT_USAGE`, and adjust the app’s feature availability (org-wide vs single-account dashboards) accordingly.

## Concrete Artifacts

### Artifact: Org-level daily spend model (SQL draft)

Goal: create a consistent daily table the app can query for org-level dashboards. This draft also encodes the key product reality: **credits data arrives faster than currency data**, and currency can mutate before month close.

```sql
-- FACT TABLE IDEA: daily cost + credits at org level
-- Sources:
--   - SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY (currency truth; up to 72h latency; mutable until month close)
--   - SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY (credits truth; ~2h latency; 365d retention)

-- Recommended: store both signals.
-- 1) credits daily (fast)
CREATE OR REPLACE TABLE FINOPS.FACT_ORG_CREDITS_DAILY AS
SELECT
  organization_name,
  account_locator,
  account_name,
  region,
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed
FROM snowflake.organization_usage.metering_daily_history;

-- 2) currency daily (slow)
CREATE OR REPLACE TABLE FINOPS.FACT_ORG_CURRENCY_DAILY AS
SELECT
  organization_name,
  contract_number,
  account_locator,
  account_name,
  region,
  service_level,
  usage_date,
  billing_type,
  rating_type,
  service_type,
  is_adjustment,
  currency,
  usage,
  usage_in_currency,
  balance_source
FROM snowflake.organization_usage.usage_in_currency_daily;

-- 3) convenience view: currency + credits joined on account/date/service_type
-- Note: the join key depends on matching service_type semantics between the two views.
-- If service_type doesn’t align for some rows, keep them separate and surface “unmatched” counts.
CREATE OR REPLACE VIEW FINOPS.V_ORG_DAILY_SPEND AS
SELECT
  c.organization_name,
  c.account_locator,
  c.account_name,
  c.region,
  c.usage_date,
  c.service_type,
  c.credits_used_compute,
  c.credits_used_cloud_services,
  c.credits_adjustment_cloud_services,
  c.credits_billed,
  u.currency,
  u.usage_in_currency,
  u.billing_type,
  u.rating_type,
  u.is_adjustment,
  u.balance_source
FROM FINOPS.FACT_ORG_CREDITS_DAILY c
LEFT JOIN FINOPS.FACT_ORG_CURRENCY_DAILY u
  ON  u.organization_name = c.organization_name
  AND u.account_locator = c.account_locator
  AND u.usage_date = c.usage_date
  AND u.service_type = c.service_type;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `USAGE_IN_CURRENCY_DAILY` latency (up to 72h) and “mutable until month close” is not handled explicitly. | Dashboards show confusing or “wrong” spend; anomaly detection triggers on partial data. | Implement freshness flags + backfill jobs; measure day-level deltas for last 7–10 days; show “preliminary” labels. |
| Joining `METERING_DAILY_HISTORY` and `USAGE_IN_CURRENCY_DAILY` on `SERVICE_TYPE` assumes stable alignment of `SERVICE_TYPE` enumerations between the two views. | Mis-attribution of currency↔credits or missing joins. | Build unit tests: count unmatched rows; maintain mapping table if needed; document known mismatches. |
| Access to `ORGANIZATION_USAGE` requires specific roles / database privileges and differs between org account vs ORGADMIN-enabled account. | App onboarding fails or only supports single-account features. | Add an onboarding SQL probe + role guidance; gate org features when only `ACCOUNT_USAGE` is available. |

## Links & Citations

1. Exploring overall cost (Snowsight + ACCOUNT_USAGE/ORGANIZATION_USAGE; example query using `USAGE_IN_CURRENCY_DAILY`): https://docs.snowflake.com/en/user-guide/cost-exploring-overall
2. `USAGE_IN_CURRENCY_DAILY` view reference (columns + 72h latency + month-close mutability notes): https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. `METERING_DAILY_HISTORY` view reference (org-level daily credits, latency/retention): https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
4. `ORGANIZATION_USAGE` schema overview (availability + role/access notes): https://docs.snowflake.com/en/sql-reference/organization-usage
5. (Account-level) `ACCOUNT_USAGE.METERING_DAILY_HISTORY` reference (timezone note for reconciliation vs org usage): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

## Next Steps / Follow-ups

- Confirm the minimal role set for a Native App (consumer-installed) to read org-level views: when is `ORGANIZATION_USAGE_VIEWER` vs `ORGANIZATION_BILLING_VIEWER` required for each view?
- Validate `SERVICE_TYPE` compatibility between `ORG_USAGE.METERING_DAILY_HISTORY` and `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` by sampling real tenant data; if mismatch, introduce a mapping table + “unmatched” QA checks.
- Extend this into an anomaly pipeline: compare fast credits vs slow currency to estimate “preliminary” spend while waiting on currency truth.
