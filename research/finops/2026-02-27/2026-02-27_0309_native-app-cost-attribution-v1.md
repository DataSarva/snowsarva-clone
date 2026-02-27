# Research: FinOps - 2026-02-27

**Time:** 03:09 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Cost attribution building blocks for a Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `QUERY_TAG` (set via the `QUERY_TAG` session parameter), plus `WAREHOUSE_NAME/ID`, timings, and a `CREDITS_USED_CLOUD_SERVICES` field for the query. This enables attributing query activity to an application/team when query tags are consistently set. 
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credits by warehouse over the last 365 days, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only). The docs explicitly call out that these values may not match **billed** credits without using `METERING_DAILY_HISTORY`.
3. Snowflake’s recommended cost attribution approach is: use **object tags** to associate resources/users with cost centers, and **query tags** to associate individual queries when the same application issues queries for multiple teams/cost centers.
4. Resource monitors can notify and/or suspend **warehouses** when credit quotas are reached; they do **not** track serverless features/AI services, and Snowflake recommends using **budgets** for those.
5. Budgets define a **monthly** spend limit (calendar month in **UTC**) and support notifications to emails, cloud queues, or webhooks. Budgets can also trigger user-defined stored procedures at thresholds or at cycle start. Default refresh/latency is up to ~6.5 hours; a 1-hour “low latency” tier exists but increases budget compute cost.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Has `QUERY_TAG`, `WAREHOUSE_*`, timing, and cloud services credits per query; query text truncated at 100k chars. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse; latency up to 180 minutes (and up to 6 hours for `CREDITS_USED_CLOUD_SERVICES`). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Named as a join target for cost attribution; enumerates tag assignments on objects (warehouses, users, etc.). *Not fetched directly in this session; referenced by cost-attributing doc and tagging intro.* |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Named as the per-query compute cost view in cost-attributing doc; no org-wide equivalent. *Not fetched directly in this session; should be validated in an account.* |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` (e.g., metering/warehouse metering + tag refs) | Views | `ORGANIZATION_USAGE` | Org-wide rollups exist, but some views (notably `QUERY_ATTRIBUTION_HISTORY`) don’t have org-wide equivalents. Use UTC session TZ when reconciling with account usage. |
| Budgets (`SNOWFLAKE.CORE.BUDGET` class instances) | Class/object | Cost management | Budgets cover warehouse + many serverless services; can notify + invoke stored procs; refresh tier trades cost vs latency. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag coverage & drift report (FinOps hygiene):** enumerate warehouses/users with missing `cost_center` (or whatever canonical tags), and estimate “untagged credits” by joining to `WAREHOUSE_METERING_HISTORY`.
2. **Idle-cost radar per warehouse:** compute `(credits_used_compute - credits_attributed_compute_queries)` per warehouse over recent periods to identify warehouses that are burning credits while idle.
3. **Query-tag adoption audit:** track % of queries with `QUERY_TAG` present by warehouse/app/user; flag top warehouses or roles producing untagged queries.

## Concrete Artifacts

### Artifact: SQL drafts for a Native App “cost attribution source-of-truth” pipeline

> Goal: produce a daily/hourly allocation table keyed by warehouse + tag_value (e.g., COST_CENTER) and separately track query-tag-driven allocations.

#### 1) Hourly warehouse credits by warehouse tag (object tagging)

```sql
-- Allocate warehouse hourly compute credits to warehouse-level tags.
-- Based on Snowflake’s documented join pattern between WAREHOUSE_METERING_HISTORY and TAG_REFERENCES.
-- NOTE: This is "consumed" credits; billed credits require METERING_DAILY_HISTORY adjustments.

WITH wh AS (
  SELECT
    start_time,
    end_time,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
), tags AS (
  SELECT
    object_id,
    domain,
    tag_name,
    tag_value,
    tag_database,
    tag_schema
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
)
SELECT
  wh.start_time,
  wh.warehouse_name,
  tags.tag_name,
  COALESCE(tags.tag_value, 'untagged') AS tag_value,
  SUM(wh.credits_used_compute) AS credits_used_compute,
  SUM(wh.credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(wh.credits_used) AS credits_used_total
FROM wh
LEFT JOIN tags
  ON wh.warehouse_id = tags.object_id
GROUP BY 1,2,3,4
ORDER BY 1 DESC, credits_used_total DESC;
```

#### 2) Hourly warehouse idle cost (actionable waste signal)

```sql
-- Directly from the WAREHOUSE_METERING_HISTORY documentation: idle cost over a window.

SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits,
  warehouse_name
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('days', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY idle_credits DESC;
```

#### 3) Query-tag adoption rate (for app-level chargeback)

```sql
-- QUERY_HISTORY includes QUERY_TAG; this makes it measurable.
-- Use this to measure how much query activity is attributable via query tags.

SELECT
  DATE_TRUNC('hour', start_time) AS hour,
  warehouse_name,
  COUNT(*) AS queries_total,
  SUM(IFF(query_tag IS NULL OR query_tag = '', 1, 0)) AS queries_untagged,
  (1.0 - (queries_untagged / NULLIF(queries_total, 0))) AS tagged_ratio
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
GROUP BY 1,2
ORDER BY 1 DESC, tagged_ratio ASC;
```

### Artifact: ADR sketch — “Cost attribution model inside the Native App”

**Decision:** Use a 2-track allocation model:
- **Track A (object tags):** allocate warehouse-hour credits to `WAREHOUSE` tag(s) (e.g., COST_CENTER) via `TAG_REFERENCES ⨝ WAREHOUSE_METERING_HISTORY`.
- **Track B (query tags):** allocate query-execution credits to `QUERY_TAG` when query tags are present; keep “untagged query credits” as a measurable gap.

**Why:** Snowflake’s own cost attribution guidance explicitly positions object tags for resource/user attribution and query tags for shared-application attribution.

**Implications for the app schema (minimal):**
- `ALLOC_WAREHOUSE_HOURLY(start_time, warehouse_id, tag_name, tag_value, credits_used_compute, credits_used_cloud_services, credits_used_total)`
- `QUERY_TAG_ADOPTION_HOURLY(hour, warehouse_id, queries_total, queries_untagged, tagged_ratio)`

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` view latency (warehouse metering up to 3h; cloud services column up to 6h) | Near-real-time dashboards can mislead | Document as “data freshness” in UI; optionally use longer windows or scheduled refresh. Source: WAREHOUSE_METERING_HISTORY usage notes. |
| Credits in `WAREHOUSE_METERING_HISTORY` / `QUERY_HISTORY` are “consumed” and may not equal billed credits (cloud services adjustment) | Incorrect $ chargeback if treated as billed | Use `METERING_DAILY_HISTORY` (not deeply fetched here) for billed reconciliation; keep both “consumed credits” and “billed credits” concepts explicit. |
| `QUERY_ATTRIBUTION_HISTORY` availability/permissions vary | May block per-query cost allocation without elevated privileges | Validate required roles (e.g., USAGE_VIEWER / cost mgmt roles) in a target account; fall back to warehouse-hour allocation when unavailable. |
| Budgets low-latency tier increases compute cost | Over-monitoring becomes a cost center | Expose as a configuration knob with clear trade-off text; default to standard refresh tier. |

## Links & Citations

1. Snowflake docs — `QUERY_HISTORY` view (includes `QUERY_TAG` column): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
2. Snowflake docs — `WAREHOUSE_METERING_HISTORY` view (hourly credits, latency notes, idle-cost example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake docs — Attributing cost (recommended object tags + query tags; join patterns and referenced views): https://docs.snowflake.com/en/user-guide/cost-attributing
4. Snowflake docs — Object tagging introduction (tags to monitor resource usage; references `TAG_REFERENCES`): https://docs.snowflake.com/en/user-guide/object-tagging/introduction
5. Snowflake docs — Resource monitors (warehouse-only; budgets for serverless/AI): https://docs.snowflake.com/en/user-guide/resource-monitors
6. Snowflake docs — Budgets (monthly UTC, notifications + stored-proc actions, refresh tier trade-off): https://docs.snowflake.com/en/user-guide/budgets
7. Snowflake docs — Exploring compute cost (positioning of ACCOUNT_USAGE/ORGANIZATION_USAGE + billed nuance): https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Validate `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` columns + join keys to map query credits to `QUERY_HISTORY` (`QUERY_ID`) in a real account.
- Fetch and pin docs for `TAG_REFERENCES` + `QUERY_ATTRIBUTION_HISTORY` + `METERING_DAILY_HISTORY` to tighten the “billed vs consumed” model with citations.
- Convert the ADR sketch into a real app-internal schema + incremental backfill plan (hourly loader task, 365-day window management, and org-wide mode).
