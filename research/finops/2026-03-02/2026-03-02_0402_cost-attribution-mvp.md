# Research: FinOps - 2026-03-02

**Time:** 04:02 UTC  
**Topic:** Snowflake FinOps Cost Attribution primitives (tags, query attribution, billed vs attributed credits)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended pattern for cost attribution is: **object tags** for resources/users and **query tags** when a shared application/warehouse needs per-query attribution across departments/projects.  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Cost attribution is fundamentally different for **dedicated resources** (attribute warehouse credits by warehouse tag) vs **shared resources** (attribute query costs using `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`, then optionally allocate idle time proportionally).  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes both total warehouse compute credits and a column for credits attributed to compute queries; the difference can be used as a measure of **warehouse idle cost**.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides hourly credit usage by **service type** (compute + cloud services) with documented latency (up to ~180 minutes for most data; some service-specific delays). This is the base primitive for “where are credits going beyond warehouses?”.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
5. Snowflake documents that the `QUERY_ATTRIBUTION_HISTORY` “cost per query” excludes non-warehouse credit costs (storage, data transfer, serverless features, token-based AI services, etc.) and excludes warehouse idle time.  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | `ACCOUNT_USAGE` | Tag->object mapping; join key differs by domain (e.g., warehouse uses `OBJECT_ID` ~= `WAREHOUSE_ID`). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly per-warehouse credits; includes `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for idle-cost estimation. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | `ACCOUNT_USAGE` | Per-query compute attribution + query acceleration credits; excludes idle time and non-query costs. (No org-wide equivalent per docs.) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly credits by `SERVICE_TYPE` across the account; broad “everything credits” breakdown. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ORG_USAGE` | Org-wide warehouse hourly credits. (Useful for dedicated-resource attribution across accounts.) |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | view | `ORG_USAGE` | Only in the **organization account** per docs; enables org-wide warehouse tag joins for dedicated resources. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution “mode detector”**: for each warehouse, decide whether to attribute by warehouse tag (dedicated) vs by query tags/users (shared) based on observed tag coverage + number of distinct `USER_NAME` / `QUERY_TAG` producers.
2. **Idle-cost accounting switch**: for shared attribution reports, expose two toggles:
   - “attributed” (sum of `QUERY_ATTRIBUTION_HISTORY.CREDITS_ATTRIBUTED_COMPUTE`)
   - “billed compute” (allocate warehouse compute credits incl. idle using proportional allocation).
3. **Non-warehouse credits radar**: daily rollup from `ACCOUNT_USAGE.METERING_HISTORY` by `SERVICE_TYPE` to identify top serverless / cloud-services drivers (e.g., `AUTO_CLUSTERING`, `SEARCH_OPTIMIZATION`, `SNOWPARK_CONTAINER_SERVICES`, `AI_SERVICES`, etc.).

## Concrete Artifacts

### SQL draft: Cost attribution by tag (dedicated warehouses) + idle cost per warehouse

```sql
-- Dedicated-resource showback (warehouse-level) for last full month.
-- Source pattern: Snowflake docs on attributing cost via TAG_REFERENCES + WAREHOUSE_METERING_HISTORY.
-- https://docs.snowflake.com/en/user-guide/cost-attributing

WITH month_window AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS end_ts
),
wh AS (
  SELECT
    wmh.warehouse_id,
    wmh.warehouse_name,
    wmh.start_time,
    wmh.credits_used_compute,
    wmh.credits_used_cloud_services,
    wmh.credits_attributed_compute_queries,
    (wmh.credits_used_compute - wmh.credits_attributed_compute_queries) AS idle_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history wmh
  JOIN month_window mw
    ON wmh.start_time >= mw.start_ts AND wmh.start_time < mw.end_ts
),
wh_tags AS (
  SELECT
    tr.object_id AS warehouse_id,
    tr.tag_name,
    tr.tag_value
  FROM snowflake.account_usage.tag_references tr
  WHERE tr.domain = 'WAREHOUSE'
)
SELECT
  COALESCE(NULLIF(wh_tags.tag_value, ''), 'untagged') AS cost_center,
  SUM(wh.credits_used_compute) AS compute_credits,
  SUM(wh.idle_compute_credits) AS idle_compute_credits,
  SUM(wh.credits_used_cloud_services) AS cloud_services_credits
FROM wh
LEFT JOIN wh_tags
  ON wh.warehouse_id = wh_tags.warehouse_id
 AND wh_tags.tag_name = 'COST_CENTER'
GROUP BY 1
ORDER BY compute_credits DESC;
```

### SQL draft: Account-wide credits by service type (find “everything beyond warehouses”)

```sql
-- Hourly credits by service type (last 30 days)
-- https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

SELECT
  service_type,
  entity_type,
  name,
  DATE_TRUNC('DAY', start_time) AS day,
  SUM(credits_used_compute)        AS credits_compute,
  SUM(credits_used_cloud_services) AS credits_cloud_services,
  SUM(credits_used)               AS credits_total
FROM snowflake.account_usage.metering_history
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4
ORDER BY credits_total DESC
LIMIT 200;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Org-wide query-level attribution is not possible with a single org-level view (per docs, `QUERY_ATTRIBUTION_HISTORY` is account-scoped). | The Native App must either (a) run per-account and aggregate externally, or (b) accept partial org-level views for query attribution. | Confirm in Snowflake docs + test in an org account: attempt `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (should not exist). Source: https://docs.snowflake.com/en/user-guide/cost-attributing |
| Tag enforcement is a hard prerequisite for reliable attribution (untagged objects/users/queries create “unknown” buckets). | Reports may be misleading; teams may reject chargeback. | Add “tag coverage” KPIs + alerting; validate by checking % untagged over time via `TAG_REFERENCES`. |
| `CREDITS_USED` in warehouse metering may not equal billed credits due to cloud services adjustments (doc note). | Reconciliation issues vs invoices; trust hit. | Use Snowflake’s documented “billed credits” sources for reconciliation (needs follow-up: identify exact view(s) and mapping). Source note: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Pull the Snowflake doc for **billed credits reconciliation** that `WAREHOUSE_METERING_HISTORY` references (it mentions using `METERING_DAILY_HISTORY` to determine billed credits) and draft a clean reconciliation model for the Native App UI.
- Add a “cost attribution maturity checklist” to the app (tag DB replication, mandatory tags on warehouses/users, query tag conventions, untagged detection queries).
- Research org-account mechanics/privileges for reading `ORGANIZATION_USAGE.TAG_REFERENCES` and `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` from a Native App context.
