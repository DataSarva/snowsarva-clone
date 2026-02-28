# Research: FinOps - 2026-02-28

**Time:** 02:42 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, including compute credits and cloud services credits; it also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which **excludes idle time**. 
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` can be **greater than billed credits** because it does not account for the cloud services billing adjustment; Snowflake directs users to `METERING_DAILY_HISTORY` to determine credits actually billed.
3. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` shows **direct** object↔tag associations (not inheritance) and includes `APPLY_METHOD` to indicate whether a tag was assigned manually vs propagated vs classified.
4. Snowflake’s recommended cost attribution approach is to use **object tags** for resources/users and **query tags** (`QUERY_TAG`) when an application issues queries on behalf of multiple cost centers.
5. Resource monitors are for **warehouses only** (not serverless features / AI services), and can notify and/or suspend warehouses when thresholds are reached.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only, no idle). Latency up to ~180 minutes (and up to ~6 hours for cloud services column). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata incl. `WAREHOUSE_NAME`, `ROLE_NAME`, `USER_NAME`, and `QUERY_TAG` (session parameter). |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag associations; no inheritance; includes `APPLY_METHOD`; latency up to ~120 minutes; filtered by privileges of current role. |
| `RESOURCE MONITOR` | Object | N/A | First-class object for warehouse credit quota/threshold actions (notify/suspend). Not for serverless/AI services; use budgets for those. |
|

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag-based showback dashboard (warehouse-only, hourly/daily rollups):** join `WAREHOUSE_METERING_HISTORY` ↔ `TAG_REFERENCES` for warehouse tags to compute credits by `cost_center` (and explicitly compute “idle estimate” as compute minus attributed query compute).
2. **Query-tag coverage + enforcement hints:** compute % of warehouse/query spend that is attributable to a non-null `QUERY_HISTORY.QUERY_TAG`; highlight top warehouses/roles/users generating untagged spend.
3. **Resource monitor policy auditor:** surface current resource monitors, their quotas/schedules/actions, and flag accounts relying on monitors for things they can’t cover (serverless/AI), pointing them to budgets.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Daily showback by warehouse tag + idle estimate

```sql
-- Purpose:
--   Attribute warehouse compute credits to a tag (e.g., COST_CENTER) and
--   compute an "idle estimate" using Snowflake's documented relationship:
--     idle_estimate = SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)
-- Notes:
--   - TAG_REFERENCES is direct associations only (no inheritance).
--   - CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes idle time.
--   - This is consumption accounting (credits). Billed credits may differ.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH metering AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS day,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute)                  AS credits_used_compute,
    SUM(credits_used_cloud_services)           AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries)    AS credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_DATE())
  GROUP BY 1,2,3
), wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    MAX(IFF(tag_name ILIKE 'COST_CENTER', tag_value, NULL)) AS cost_center
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
    AND object_deleted IS NULL
  GROUP BY 1
)
SELECT
  m.day,
  COALESCE(t.cost_center, 'untagged') AS cost_center,
  SUM(m.credits_used_compute) AS credits_used_compute,
  SUM(m.credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(m.credits_attributed_compute_queries) AS credits_attributed_compute_queries,
  (SUM(m.credits_used_compute) - SUM(m.credits_attributed_compute_queries)) AS idle_estimate_credits
FROM metering m
LEFT JOIN wh_tags t
  ON m.warehouse_id = t.warehouse_id
GROUP BY 1,2
ORDER BY m.day DESC, credits_used_compute DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tag inheritance is **not** represented in `ACCOUNT_USAGE.TAG_REFERENCES`. If teams rely on account/db/schema-level tagging, attribution could miss inherited tags. | Under-attribution / “untagged” inflation. | Use tag lineage functions/views where available (e.g., `TAG_REFERENCES_WITH_LINEAGE`) or enforce direct tagging on warehouses/users for cost. |
| Account usage views have **latency** (2–6 hours depending on view/column). | Near-real-time dashboards may mislead. | Communicate freshness; optionally use `INFORMATION_SCHEMA` / eventing patterns for near real-time where possible. |
| Credits in usage views may not equal **billed** credits (e.g., cloud services adjustment; billing in currency). | Mismatch between showback and finance invoices. | Provide a “consumption vs billed” toggle: consumption from `WAREHOUSE_METERING_HISTORY`; billed from `METERING_DAILY_HISTORY` and org currency views where available. |
| Resource monitors do **not** cover serverless/AI services. | False sense of budget protection if relying only on monitors. | Detect usage of serverless/AI and recommend budgets in-app; document the scope clearly. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY view (columns, latency, idle-time example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. TAG_REFERENCES view (direct associations only; `APPLY_METHOD`; latency): https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
3. Attributing cost (recommended approach: object tags + query tags; example joins): https://docs.snowflake.com/en/user-guide/cost-attributing
4. Introduction to object tagging (tags as key/value; monitor resource usage; inheritance/propagation; references to tag reference functions): https://docs.snowflake.com/en/user-guide/object-tagging/introduction
5. Working with resource monitors (warehouses only; thresholds/actions): https://docs.snowflake.com/en/user-guide/resource-monitors
6. QUERY_HISTORY view (`QUERY_TAG`, warehouse/user/role fields): https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Pull `QUERY_ATTRIBUTION_HISTORY` docs and draft a second attribution path for **shared warehouses** (user-level / query-level attribution).
- Draft a minimal internal schema for the Native App (daily facts + tag dimensions + freshness watermark) to support “consumption vs billed” dual reporting.
- Define a “tagging coverage” score: % credits with a populated `COST_CENTER` (warehouse/user tags) and/or `QUERY_TAG`.
