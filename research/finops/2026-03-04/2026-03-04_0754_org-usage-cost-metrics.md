# Research: FinOps - 2026-03-04

**Time:** 07:54 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Org-level billing + cost attribution primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake cost/usage reporting can be done via Snowsight dashboards and by querying usage/cost views in `SNOWFLAKE.ACCOUNT_USAGE` and `SNOWFLAKE.ORGANIZATION_USAGE` (org-wide).  
2. Cloud services credits are **not always billed**: cloud services usage is charged only when daily cloud services consumption exceeds **10%** of daily warehouse usage; many UIs/views show total consumed credits without applying this billing adjustment. To determine credits actually billed for compute, query `METERING_DAILY_HISTORY`.  
3. To express compute spend in **currency** (not just credits), Snowflake provides `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, which converts consumed credits to currency using the daily price of a credit.  
4. Snowflake Behavior Change Ref **1584** updated several org-level billing views (including `USAGE_IN_CURRENCY_DAILY`) specifically to make reconciliation against monthly usage statements easier; changes include consistent data types, rounding alignment, and new columns such as `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT`.  
5. `ACCOUNT_USAGE` views have data latency (generally 45 minutes to 3 hours depending on view) and retain historical usage up to **1 year**; Information Schema has no latency but shorter retention. `ACCOUNT_USAGE` also includes dropped-object records and IDs.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily credits + cost in currency (org currency). Includes columns to support reconciliation (see BCR-1584). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits across warehouses/serverless/cloud services; includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` enabling billed cloud services calculation. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits per warehouse (includes cloud services component associated with the warehouse). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Per-query metadata incl. `CREDITS_USED_CLOUD_SERVICES`; can attribute cloud services-heavy query types. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Credits consumed per query for warehouse usage (used for deeper attribution; note longer latency in Account Usage). |
| Snowsight → Admin → Cost Management | UI | Snowsight | Shows consumption; supports filtering by tag/value for cost attribution. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata/usage
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Billing-aware compute spend tile**: compute-cost dashboard that shows both *consumed* credits and *billed* compute credits (with cloud services 10% adjustment applied) using `ACCOUNT_USAGE.METERING_DAILY_HISTORY`, alongside currency conversion using `ORG_USAGE.USAGE_IN_CURRENCY_DAILY`.
2. **Org-level chargeback baseline**: a daily fact table keyed by `ORG_ID/ACCOUNT_NAME/USAGE_DATE/SERVICE_TYPE/RATING_TYPE/BILLING_TYPE` sourced from `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` (post-BCR-1584 columns) to power cross-account spend breakdown and contract reconciliation.
3. **Anomaly candidate finder (cloud services-heavy warehouses)**: implement the doc’s “warehouses with high cloud services usage” query as a saved analysis and surface top offenders + links to the top cloud-services-cost queries.

## Concrete Artifacts

### Billing-aware daily cost fact (SQL draft)

Goal: establish a canonical “daily billing truth” dataset that (a) matches statement reconciliation semantics as closely as possible and (b) supports attribution dimensions used by the app.

```sql
-- FACT TABLE IDEA (daily): FINOPS_DAILY_COST
-- NOTE: Column availability differs by schema/edition/role.
-- Use ORG_USAGE where available (org-wide + currency). Use ACCOUNT_USAGE for billed cloud services adjustments.

-- 1) ORG-level: daily usage in currency (compute/storage/transfer etc) + reconciliation columns (post BCR-1584)
WITH org_currency AS (
  SELECT
    usage_date,
    account_name,
    service_type,
    billing_type,
    rating_type,
    is_adjustment,
    usage,                 -- credits (data type changed in BCR-1584)
    usage_in_currency      -- currency (data type changed in BCR-1584)
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD('day', -90, CURRENT_DATE())
),

-- 2) Account-level: billed cloud services adjustment (credits)
-- The docs explicitly recommend METERING_DAILY_HISTORY to determine credits actually billed.
account_billed_cloud_services AS (
  SELECT
    usage_date,
    -- these are credits; billed cloud services is credits_used_cloud_services + credits_adjustment_cloud_services
    credits_used_cloud_services,
    credits_adjustment_cloud_services,
    (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD('day', -90, CURRENT_DATE())
)

SELECT
  o.usage_date,
  o.account_name,
  o.service_type,
  o.billing_type,
  o.rating_type,
  o.is_adjustment,
  o.usage AS credits_consumed,
  o.usage_in_currency AS cost_in_currency,

  -- Optional: If you want to present “billed compute credits”, keep this separate because ORG_USAGE already reflects billing semantics
  -- and ACCOUNT_USAGE represents a single account. Joining needs careful account mapping (account locator vs account name).
  a.billed_cloud_services_credits

FROM org_currency o
LEFT JOIN account_billed_cloud_services a
  ON a.usage_date = o.usage_date
-- NOTE: This join is incomplete in pure SQL because ACCOUNT_USAGE lacks org-wide account_name.
-- In a native app, you’d materialize per-account datasets separately and UNION ALL with account locator metadata.
;
```

### “High cloud services ratio” detector (ready-to-ship query)

```sql
-- Warehouses with high cloud services usage over the last month
-- Source query pattern from Snowflake docs.
SELECT
  warehouse_name,
  SUM(credits_used) AS credits_used_total,
  SUM(credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(credits_used_cloud_services) / NULLIF(SUM(credits_used), 0) AS pct_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE TO_DATE(start_time) >= DATEADD(month, -1, CURRENT_TIMESTAMP())
  AND credits_used_cloud_services > 0
GROUP BY 1
ORDER BY 4 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Joining org-level currency facts (`ORG_USAGE.USAGE_IN_CURRENCY_DAILY`) to account-level billed adjustments (`ACCOUNT_USAGE.METERING_DAILY_HISTORY`) requires a stable account identifier mapping (e.g., locator) not shown in the excerpts. | Wrong attribution across accounts; misleading “billed vs consumed” comparisons. | Confirm which org usage views include account locator / org ID columns; validate via Snowflake docs or by introspecting view DDL in a real org account. |
| `ORG_USAGE` billing views may not be accessible without org-level roles; some customers (resellers / on-demand) have limitations in Snowsight access to currency. | App must degrade gracefully (credits-only mode). | Confirm role requirements and availability matrix for `ORGANIZATION_USAGE` in org account. |
| Reconciliation rules include rounding/threshold behavior (e.g., <$0.01 not billed) mentioned in BCR-1584 “before change” behavior. | Without mirroring statement semantics, dashboards will disagree with invoices. | Use updated columns (`IS_ADJUSTMENT`, `RATING_TYPE`, etc.) and test against a statement export where possible. |

## Links & Citations

1. Snowflake docs: Cost & billing (overview) — https://docs.snowflake.com/en/guides-overview-cost
2. Snowflake docs: Exploring compute cost (views, currency view, cloud services billed rule; includes example queries) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake release note: Org Usage updated billing views (BCR-1584) — https://docs.snowflake.com/en/release-notes/bcr-bundles/un-bundled/bcr-1584
4. Snowflake reference: Account Usage (latency/retention + database roles + UTC reconciliation note) — https://docs.snowflake.com/en/sql-reference/account-usage

## Next Steps / Follow-ups

- Pull the docs for org-level billing schema specifics (which views carry account identifiers, contract identifiers, and how to reconcile statement line-items end-to-end).
- Draft an ADR for “Canonical Cost Fact v1” defining: (a) consumed vs billed metrics, (b) currency conversion, (c) dimensionality (service_type/billing_type/rating_type/tag).
- Add a native-app data model that can operate in three modes: org-wide (currency), account-only (credits), and hybrid (org currency + per-account billed adjustments), with explicit disclaimers.
