# Research: FinOps - 2026-03-01

**Time:** 0003 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake exposes two closely-related ways to retrieve hourly warehouse credit usage:
   - `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` table function (last **6 months**; can be incomplete for long ranges across many warehouses) and
   - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view (last **365 days**; has latency, but designed for longer retention / completeness).  
   Source: https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes both total credits (`CREDITS_USED`) and components (`CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`). It also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which explicitly **excludes warehouse idle time** (Snowflake provides an example computing idle cost as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

3. Account Usage views are not real-time; `WAREHOUSE_METERING_HISTORY` latency is up to **~180 minutes**, while the `CREDITS_USED_CLOUD_SERVICES` column can lag up to **~6 hours**.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

4. For account-level service-type breakouts (serverless features, AI, etc.), `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides hourly credits by `SERVICE_TYPE` (e.g., `WAREHOUSE_METERING`, `SNOWPIPE_STREAMING`, `SERVERLESS_TASK`, `AI_SERVICES`, etc.).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

5. Cost attribution “by tag” is a first-class pattern in Snowflake docs:
   - use `ACCOUNT_USAGE.TAG_REFERENCES` to map tags → objects/users
   - join with `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (warehouse tagging) and/or `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (user/query tagging).  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing

6. When reconciling Account Usage cost views with Organization Usage equivalents, Snowflake recommends setting the session timezone to UTC first (this matters for joining/aggregating across datasets).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

7. Snowflake’s Well-Architected “Cost Optimization (FinOps)” guide explicitly recommends a consistent tagging strategy and references using `ACCOUNT_USAGE.TAG_REFERENCES` combined with usage views like `WAREHOUSE_METERING_HISTORY` for allocation/showback.  
   Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | INFO_SCHEMA | Hourly warehouse credits; last 6 months; requires `ACCOUNTADMIN` or role w/ `MONITOR USAGE` global privilege. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; last 365 days; latency up to ~3h (cloud services up to ~6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by `SERVICE_TYPE` across the account; helps build “what services are spending” breakdowns beyond warehouses. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Map of tag assignments (and inherited/propagated tags) to objects (incl. WAREHOUSE, USER, etc.). Used for cost allocation joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Mentioned in cost attribution docs for allocating query execution costs; (idle time handling requires separate logic). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Cost allocation by warehouse tag (showback/chargeback MVP):** A small “allocation mart” that produces daily/monthly credits by `tag_name/tag_value` using `TAG_REFERENCES` + `WAREHOUSE_METERING_HISTORY`. This can back both Snowsight dashboards and a Native App UI.

2. **Idle-time surfaced as first-class metric:** For each warehouse, compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` and track idle% over time. This becomes a concrete optimization surface (autosuspend, workload isolation, multi-cluster vs size-up).

3. **Service-type cost dashboard (serverless/AI visibility):** Use `METERING_HISTORY` to show daily/hourly credits by `SERVICE_TYPE` (e.g., `SNOWPIPE_STREAMING`, `SERVERLESS_TASK`, `AI_SERVICES`) so costs don’t get “lost” when teams focus only on warehouses.

## Concrete Artifacts

### Artifact: SQL draft — monthly warehouse compute credits by object tag (includes idle)

Goal: attribute **billed warehouse compute** (including idle) by an object tag (e.g., `COST_CENTER`). This follows Snowflake’s documented pattern of joining `TAG_REFERENCES` to `WAREHOUSE_METERING_HISTORY`, with a few practical add-ons:
- constrain to a specific `tag_database/tag_schema/tag_name`
- normalize untagged as `untagged`
- compute idle credits explicitly using documented columns

```sql
-- Compute credits by warehouse tag value for last full month.
-- Includes *idle* compute (because it uses credits_used_compute).
--
-- Prereq: the execution role needs access to ACCOUNT_USAGE views.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wmh AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE()))
    AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE())
),
warehouse_tags AS (
  SELECT
    object_id        AS warehouse_id,
    tag_database,
    tag_schema,
    tag_name,
    tag_value
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
    -- Optional hardening to a single tag namespace:
    -- AND tag_database = 'COST_MANAGEMENT'
    -- AND tag_schema   = 'TAGS'
    -- AND tag_name     = 'COST_CENTER'
)
SELECT
  wt.tag_database,
  wt.tag_schema,
  wt.tag_name,
  COALESCE(wt.tag_value, 'untagged')                 AS tag_value,
  SUM(wmh.credits_used_compute)                      AS compute_credits_including_idle,
  SUM(wmh.credits_attributed_compute_queries)        AS compute_credits_attributed_to_queries_excluding_idle,
  SUM(wmh.credits_used_compute) -
    SUM(wmh.credits_attributed_compute_queries)      AS idle_compute_credits,
  DIV0NULL(idle_compute_credits, compute_credits_including_idle) AS idle_credit_ratio
FROM wmh
LEFT JOIN warehouse_tags wt
  ON wmh.warehouse_id = wt.warehouse_id
GROUP BY 1,2,3,4
ORDER BY compute_credits_including_idle DESC;
```

Notes:
- `credits_attributed_compute_queries` explicitly excludes idle time, so `credits_used_compute - credits_attributed_compute_queries` is a direct “idle compute credits” measure (Snowflake example uses this pattern).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tagging coverage is incomplete (untagged warehouses/users) | Allocation results won’t balance cleanly by cost center; operational friction | Add “untagged” reporting and a weekly enforcement report using `TAG_REFERENCES` to find missing tags. |
| Account Usage latency (3h / 6h) | Near-real-time dashboards can look wrong / incomplete | Use data freshness watermark; for “today” use caution or delay, and/or combine with Information Schema for recent hours where appropriate. |
| Cloud services credits behave differently (10% rule, separate latency) | Cost-by-warehouse views may under/over-emphasize cloud services drivers | Build a separate `METERING_HISTORY` service-type view for holistic account costs. |
| `QUERY_ATTRIBUTION_HISTORY` availability/semantics vary by account/edition/feature rollout | Shared-warehouse cost attribution may be blocked or inaccurate | Confirm in target accounts; fall back to warehouse-level tagging + query_tag-based approaches where feasible. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY (Information Schema table function): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
2. WAREHOUSE_METERING_HISTORY (Account Usage view): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. METERING_HISTORY (Account Usage view): https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Attributing cost (tags + example joins): https://docs.snowflake.com/en/user-guide/cost-attributing
5. Snowflake Well-Architected: Cost Optimization & FinOps: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Pull the exact schema for `ACCOUNT_USAGE.TAG_REFERENCES` (columns + semantics like inheritance/propagation) and design a durable “tag dimension” table for the app.
- Decide MVP allocation model(s):
  - dedicated resources (warehouse tags) vs
  - shared warehouses (query tags / user tags + query attribution)
- Add a standard “data freshness” widget to the app: last available `wmh.start_time`, last available `metering_history.start_time`.
