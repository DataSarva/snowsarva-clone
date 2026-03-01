# Research: FinOps - 2026-03-01

**Time:** 06:32 UTC  
**Topic:** Snowflake FinOps Cost Allocation Across Accounts (ORG_USAGE + Tags)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake cost/usage visibility can be queried via **ACCOUNT_USAGE** (single account) and **ORGANIZATION_USAGE** (organization-wide) schemas; Snowsight Cost Management is effectively a UI over these types of sources. (Exploring compute cost doc)
2. Most cost/usage views expose **credits consumed**, and Snowflake provides a specific **USAGE_IN_CURRENCY_DAILY** view (in ORGANIZATION_USAGE) to convert credit consumption into currency using the daily price of a credit. (Exploring compute cost doc)
3. **Cloud services credits are only billed** if daily cloud services consumption exceeds **10%** of daily warehouse usage; many views show raw consumption and do not automatically apply the daily billed adjustment. (Exploring compute cost doc)
4. For cost attribution/chargeback, Snowflake’s recommended approach is: **object tags** for resources/users and **query tags** when an application executes queries on behalf of multiple cost centers. (Attributing cost doc)
5. Org-wide attribution via tags is feasible for **resources exclusively owned by a department** because you can join org-wide usage with tag references from the **organization account**; however **QUERY_ATTRIBUTION_HISTORY has no organization-wide equivalent** (it exists only in ACCOUNT_USAGE). (Attributing cost doc)
6. WAREHOUSE_METERING_HISTORY provides hourly warehouse credits and includes a field for credits attributed to queries; **idle time is not included** in credits attributed to queries and can be computed as a difference at the warehouse level. (WAREHOUSE_METERING_HISTORY view doc)
7. METERING_HISTORY provides hourly credit usage by service_type at the account level, and its total credits may be higher than billed because it may not reflect the cloud services adjustment. (METERING_HISTORY view doc)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | view | ORG_USAGE | Org-wide hourly warehouse credits (credits_used_compute / credits_used_cloud_services). Mentioned as available in ORG_USAGE in compute cost docs. |
| SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY | view | ORG_USAGE | Daily credits across compute resources; can be used to determine whether cloud services was billed (10% rule) using credits_adjustment_cloud_services. (Compute cost doc) |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY | view | ACCOUNT_USAGE | Hourly credits by service_type for an account; includes compute + cloud services columns; latency up to ~3–6h. (METERING_HISTORY doc) |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse usage for last 365 days; includes CREDITS_ATTRIBUTED_COMPUTE_QUERIES (no idle). (WAREHOUSE_METERING_HISTORY doc) |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query compute attribution for warehouse execution; no org-wide equivalent. (Attributing cost doc) |
| SNOWFLAKE.(ACCOUNT_USAGE|ORGANIZATION_USAGE).TAG_REFERENCES | view | ACCOUNT_USAGE / ORG_USAGE | In ORG_USAGE, TAG_REFERENCES is only available in the **organization account**; used to map object_id→tag_value for chargeback. (Attributing cost doc) |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | view | ORG_USAGE | Converts credits to currency using daily credit price. (Compute cost doc) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide showback by tag (warehouse-owned workloads):** Build a daily job that joins ORG_USAGE.WAREHOUSE_METERING_HISTORY with ORG_USAGE.TAG_REFERENCES (from org account) to produce `cost_center → credits` (and currency if desired) for the organization.
2. **Idle-time spotlighting:** For each warehouse, compute `idle_cost = credits_used_compute - credits_attributed_compute_queries` (ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY) and surface “top idle spend” as a default FinOps insight.
3. **Cloud services billed-vs-consumed reconciliation panel:** Using METERING_DAILY_HISTORY (ACCOUNT_USAGE or ORG_USAGE), compute `billed_cloud_services = credits_used_cloud_services + credits_adjustment_cloud_services` and show when cloud services crossed the 10% threshold.

## Concrete Artifacts

### ADR-0001: Cost allocation strategy hierarchy (Org-wide first, per-account deep dive)

**Status:** draft  
**Decision:** In the FinOps Native App, implement cost allocation in **tiers** based on which schema is available and the attribution granularity required.

**Context / constraints (from sources):**
- ORG_USAGE enables organization-wide rollups and currency conversion, but per-query attribution is not org-wide (QUERY_ATTRIBUTION_HISTORY is only ACCOUNT_USAGE). (Attributing cost; Exploring compute cost)
- Many credit-usage views show consumption that may not match billed cloud services due to the daily adjustment rule; reconciliation must use METERING_DAILY_HISTORY when required. (Exploring compute cost)
- Idle time is not attributed to queries; a chargeback model must either (a) ignore it, (b) allocate it proportionally, or (c) attribute it to warehouse owners/cost centers. (WAREHOUSE_METERING_HISTORY; Attributing cost)

**Decision details:**
1. **Tier A (Org-wide showback, low friction):** Use ORG_USAGE.WAREHOUSE_METERING_HISTORY + ORG_USAGE.TAG_REFERENCES to allocate warehouse costs to warehouse owner tags (e.g., COST_CENTER). Works well when warehouses are dedicated.
2. **Tier B (Per-account shared warehouse allocation):** Within each account, use ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (optionally joined to TAG_REFERENCES for USER tags or query tags) for shared warehouses.
3. **Tier C (Reconciliation and billing truth):** For “billed” cloud services, compute from (ACCOUNT_USAGE|ORG_USAGE).METERING_DAILY_HISTORY, not from raw hourly consumption views.

**Consequences:**
- We can deliver org-wide dashboards even when customers refuse to enable per-query attribution pipelines across every account.
- For shared warehouses, the app needs an **account-by-account** ingestion job (or delegated procedure) to compute query-level allocations.

### SQL Draft: Org-wide warehouse credits by COST_CENTER tag (monthly)

```sql
-- PURPOSE
--   Organization-wide (multi-account) showback by warehouse tag.
--   Designed for the organization account context.
--
-- SOURCES
--   - ORG_USAGE.WAREHOUSE_METERING_HISTORY exists for org-wide warehouse credits. (Exploring compute cost)
--   - ORG_USAGE.TAG_REFERENCES is only available in the organization account. (Attributing cost)
--
-- ASSUMPTIONS
--   - Tag database/schema are stable identifiers (adjust filters as needed).
--   - Domain value for warehouses is 'WAREHOUSE'. (as shown in Snowflake examples)

ALTER SESSION SET TIMEZONE = 'UTC'; -- recommended when reconciling with ORG_USAGE (WAREHOUSE_METERING_HISTORY doc)

WITH wh_credits AS (
  SELECT
    warehouse_id,
    warehouse_name,
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used_compute) AS credits_used_compute
  FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
    AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE())
  GROUP BY 1,2,3
),
wh_tag AS (
  SELECT
    object_id AS warehouse_id,
    tag_name,
    tag_value
  FROM SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_database = 'COST_MANAGEMENT'
    AND tag_schema = 'TAGS'
    AND tag_name = 'COST_CENTER'
)
SELECT
  COALESCE(t.tag_value, 'untagged') AS cost_center,
  SUM(w.credits_used_compute) AS credits_used_compute
FROM wh_credits w
LEFT JOIN wh_tag t
  ON w.warehouse_id = t.warehouse_id
GROUP BY 1
ORDER BY 2 DESC;
```

### SQL Draft: Billed cloud services (daily) for reconciliation

```sql
-- PURPOSE
--   Compute the *billed* cloud services credits using daily adjustment columns.
--
-- SOURCE
--   Exploring compute cost doc: cloud services billed only if >10% of warehouse daily usage;
--   query METERING_DAILY_HISTORY to determine billed credits.

SELECT
  usage_date,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_used_cloud_services + credits_adjustment_cloud_services AS billed_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('MONTH', -1, CURRENT_DATE())
  AND credits_used_cloud_services > 0
ORDER BY billed_cloud_services DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE.TAG_REFERENCES is queried from the organization account and filters (tag_database/tag_schema) are correct. | Broken joins → misattributed showback. | Validate by sampling 5 warehouses and comparing tag values with SHOW TAGS / Snowsight UI. |
| Cross-account attribution for shared warehouses cannot be done with QUERY_ATTRIBUTION_HISTORY at org scope. | Native App must run per-account jobs for query-level allocation (or accept warehouse-level showback only). | Confirmed by Snowflake docs stating no org-wide equivalent for QUERY_ATTRIBUTION_HISTORY. (Attributing cost doc) |
| Customers may want billing in currency, not credits. | Need optional currency conversion pipeline using ORG_USAGE.USAGE_IN_CURRENCY_DAILY. | Validate columns and join keys; prototype query in org account. (Exploring compute cost doc) |
| Latency of ACCOUNT_USAGE views (3–6h typical) can make “near-real-time” dashboards misleading. | UI might show partial day; alerts could false-positive. | Bake in freshness indicators (max start_time ingested). (METERING_HISTORY / WAREHOUSE_METERING_HISTORY docs) |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. https://docs.snowflake.com/en/user-guide/cost-attributing
3. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Pull docs for ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY + sample join strategy so the app can show $-cost with consistent rollups.
- Research how to operationalize per-account QUERY_ATTRIBUTION_HISTORY ingestion from within a Native App (permissions + delegated procedures) while keeping data residency constraints.
- Draft an “idle cost policy” (ignore vs allocate proportionally vs charge to warehouse owner) and decide default behavior for the product.
