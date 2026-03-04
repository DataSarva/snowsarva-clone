# Research: FinOps - 2026-03-04

**Time:** 14:25 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, and includes columns that allow you to estimate **idle** credit usage by subtracting `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` from `CREDITS_USED_COMPUTE`. It also has documented latency (up to ~3 hours; cloud services up to ~6 hours).  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`. [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` returns **per-query compute credit attribution** (`CREDITS_ATTRIBUTED_COMPUTE`) and explicitly excludes **warehouse idle time**; the view can have up to **8 hours** latency. It also includes `QUERY_TAG` for attribution by tag.  
   Source: Snowflake docs for `QUERY_ATTRIBUTION_HISTORY`. [5]
3. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` identifies direct associations between objects and tags (not inheritance) and includes an `APPLY_METHOD` that distinguishes MANUAL vs PROPAGATED vs CLASSIFIED assignment; view latency can be up to **120 minutes**.  
   Source: Snowflake docs for `TAG_REFERENCES`. [4]
4. Snowflake’s documented recommendation for chargeback/showback is to combine **object tags** (e.g., warehouses, users) with **query tags** (for shared apps/workflows) to attribute costs to cost centers/projects.  
   Source: Snowflake docs “Attributing cost”. [3]
5. Resource monitors can control costs by tracking credits for warehouses (and associated cloud services) and triggering actions like notify/suspend; they do **not** cover serverless features/AI services (Snowflake recommends **budgets** for those).  
   Source: Snowflake docs “Working with resource monitors”. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits per warehouse; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to isolate execution vs idle; docs note billed credits reconciliation may require `METERING_DAILY_HISTORY`. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query attributed compute credits; includes `QUERY_TAG`, `USER_NAME`, `WAREHOUSE_NAME`; excludes idle; latency up to 8h. [5] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Query metadata incl `QUERY_TAG`, warehouse, timings, bytes scanned, queue times, `CREDITS_USED_CLOUD_SERVICES` (not billed-adjusted). Useful for “waste signals” (queue, spill, scan). [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Direct object↔tag mappings; does not include inheritance; includes `APPLY_METHOD`. [4] |
| Resource monitors (`CREATE RESOURCE MONITOR`, `ALTER RESOURCE MONITOR`, `SHOW RESOURCE MONITORS`) | Object/DDL | N/A | Warehouses-only; track credit quota and can suspend warehouses; not serverless/AI. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost attribution “spine” (warehouse-level):** daily/weekly cost by `cost_center` (object tag on warehouse) using `WAREHOUSE_METERING_HISTORY` joined to `TAG_REFERENCES`. Output: a canonical table the native app can chart + alert on.
2. **Idle-cost surfacing:** compute idle credits per warehouse per day (`credits_used_compute - credits_attributed_compute_queries`) and flag warehouses where idle% exceeds threshold; propose auto-suspend or resize guidance.
3. **Shared-warehouse allocation:** allocate warehouse-hour credits across `QUERY_TAG` (or user tag) using `QUERY_ATTRIBUTION_HISTORY`, with explicit handling of idle credits (either separate bucket or proportional allocation).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: attribute warehouse credits to a cost_center tag (+ idle estimate)

Assumptions / notes:
- Uses the documented *estimate* for idle cost: `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)` from `WAREHOUSE_METERING_HISTORY`. [1]
- `TAG_REFERENCES` contains only **direct** tag relationships; if you rely on inheritance, you’ll need to decide whether you want direct-only attribution or a “resolved tag” pipeline (not covered here). [4]

```sql
-- Cost by cost_center tag (warehouse-tagged), daily rollup
-- Customize tag name and schema as needed.

WITH wh_daily AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS day,
    warehouse_name,
    SUM(credits_used) AS credits_used_total,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
    -- Documented technique to estimate idle compute credits (hourly granularity in the source view) [1]
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS credits_idle_est
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_DATE())
  GROUP BY 1, 2
),

wh_cost_center AS (
  SELECT
    object_name AS warehouse_name,
    tag_value  AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_name ILIKE 'COST_CENTER'
    AND object_deleted IS NULL
)

SELECT
  d.day,
  COALESCE(t.cost_center, 'UNMAPPED') AS cost_center,
  SUM(d.credits_used_total) AS credits_used_total,
  SUM(d.credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(d.credits_used_compute) AS credits_used_compute,
  SUM(d.credits_attributed_compute_queries) AS credits_attributed_compute_queries,
  SUM(d.credits_idle_est) AS credits_idle_est
FROM wh_daily d
LEFT JOIN wh_cost_center t
  ON d.warehouse_name = t.warehouse_name
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

### SQL draft: allocate per-query compute credits by QUERY_TAG (shared apps/workflows)

Notes:
- `QUERY_ATTRIBUTION_HISTORY` includes `QUERY_TAG` and the per-query compute credits (`CREDITS_ATTRIBUTED_COMPUTE`). [5]
- This view excludes warehouse idle time; keep that as a separate bucket or allocate it with a policy (e.g., proportional to compute credits). [5]

```sql
-- Query compute credits by query_tag
SELECT
  DATE_TRUNC('DAY', start_time) AS day,
  COALESCE(NULLIF(query_tag, ''), 'UNSET') AS query_tag,
  SUM(credits_attributed_compute) AS attributed_compute_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_DATE())
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES` does not include inheritance. | If customers rely on inheritance (e.g., tagging at account/database), direct joins may under-attribute. | Confirm whether we want direct-only vs resolved-tag strategy; evaluate `TAG_REFERENCES` table functions for lineage/inheritance if needed. [4] |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is not billed-adjusted for cloud services; billed reconciliation may require `METERING_DAILY_HISTORY`. | Dashboards might not reconcile to invoices without additional logic. | Add a “billed credits” mode using `METERING_DAILY_HISTORY` (follow-up). [1] |
| View latency (2–8 hours depending on view) creates “near-real-time” gaps. | Alerts may lag; app UX must show freshness windows. | Document per-view latency in UI and schedule tasks accordingly. [1][4][5] |
| Resource monitors don’t cover serverless/AI services. | Users may assume monitors cap total spend. | In-product copy: recommend budgets for serverless/AI; monitor is warehouse-only. [2] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/user-guide/resource-monitors
3. https://docs.snowflake.com/en/user-guide/cost-attributing
4. https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
5. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
6. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Pull docs for `METERING_DAILY_HISTORY` and design a reconciliation mode ("used" vs "billed").
- Evaluate the best Snowflake-native way to resolve **effective** tag values (including inheritance/propagation) for warehouses/users for consistent cost attribution.
- Define a policy for allocating idle credits (separate bucket vs proportional allocation) and test against a real account’s workload patterns.
