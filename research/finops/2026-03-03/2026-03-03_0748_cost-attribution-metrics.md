# Research: FinOps - 2026-03-03

**Time:** 07:48 UTC  
**Topic:** Snowflake FinOps Cost Attribution (tags + per-query attribution + idle time)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is to use **object tags** for resources/users and **query tags** for workloads that run on behalf of multiple departments/cost centers. [1]
2. Within a single account, Snowflake documents joining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with `...WAREHOUSE_METERING_HISTORY` (for warehouse totals) and `...QUERY_ATTRIBUTION_HISTORY` (for per-query compute attribution) to attribute compute costs by tag. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** via `CREDITS_ATTRIBUTED_COMPUTE`, but:
   - can have **up to ~8 hours latency**,
   - **excludes warehouse idle time**,
   - **excludes non-warehouse costs** (storage, transfer, cloud services, serverless, AI tokens, etc.), and
   - **short-running queries (<= ~100ms) are excluded** (per docs). [2]
4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly warehouse credits** including `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; the difference can be used as a simple definition of **hourly idle cost** (warehouse compute not attributable to queries). [3]
5. Snowflake’s “Exploring compute cost” guide calls out a set of “general cost views” including `METERING_HISTORY` (hourly), `WAREHOUSE_METERING_HISTORY`, and org-level views such as `USAGE_IN_CURRENCY_DAILY` for currency translation at org scope. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to object domains (e.g., USER, WAREHOUSE) and object identifiers/names. Used for “cost by tag” joins. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credit usage; includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 180 minutes; cloud services column up to 6 hours. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute attribution: `CREDITS_ATTRIBUTED_COMPUTE`, `QUERY_TAG`, `QUERY_HASH`, `QUERY_PARAMETERIZED_HASH`, etc. Latency up to ~8 hours; excludes idle time & non-warehouse costs; excludes very short queries. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-level warehouse metering exists; docs note you must use UTC for reconciliation vs account-level. (See usage notes on account view.) [3][4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily cost in org currency (helps convert credits → money for dashboards). Mentioned as a general cost view. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Daily “Cost Attribution Cube” table** for the Native App (per day × warehouse × cost_center × query_tag/user) using `QUERY_ATTRIBUTION_HISTORY` + `WAREHOUSE_METERING_HISTORY` and distributing idle cost proportionally.
2. **Tag hygiene report**: identify top cost drivers that are `untagged` (warehouses/users/query_tag empty) and recommend “tag these first” actions.
3. **Recurrent query cost leaderboard** using `QUERY_PARAMETERIZED_HASH` to group similar queries and surface “most expensive recurring patterns” for optimization backlog. [1][2]

## Concrete Artifacts

### SQL Draft: Daily cost attribution by query tag with idle-time allocation

Goal: produce a *daily* spend metric by `query_tag` that (a) uses per-query compute attribution and (b) allocates warehouse idle time to tags proportionally, so totals reconcile to warehouse compute.

```sql
-- DAILY cost attribution (compute credits) by QUERY_TAG
-- Sources:
--   - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (per-query compute attribution; excludes idle) [2]
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (warehouse compute totals + attributed-to-queries) [3]
--
-- Notes:
--   - QUERY_ATTRIBUTION_HISTORY excludes <=~100ms queries and excludes non-warehouse costs. [2]
--   - This allocates ONLY warehouse compute idle-time (not cloud services, storage, serverless, etc.).

WITH params AS (
  SELECT
    DATEADD('day', -30, CURRENT_DATE())::date AS start_date,
    CURRENT_DATE()::date AS end_date
),

-- 1) Per-day, per-warehouse totals
wh_day AS (
  SELECT
    TO_DATE(start_time) AS d,
    warehouse_id,
    ANY_VALUE(warehouse_name) AS warehouse_name,
    SUM(credits_used_compute) AS wh_compute_credits,
    SUM(credits_attributed_compute_queries) AS wh_query_attributed_credits,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS wh_idle_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE TO_DATE(start_time) >= (SELECT start_date FROM params)
    AND TO_DATE(start_time) <  (SELECT end_date   FROM params)
    AND warehouse_id > 0 -- skip pseudo warehouses like CLOUD_SERVICES_ONLY (per Snowflake guide example) [4]
  GROUP BY 1, 2
),

-- 2) Per-day, per-warehouse, per-query_tag totals (query-attributed compute only)
tag_day AS (
  SELECT
    TO_DATE(start_time) AS d,
    warehouse_id,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_norm,
    SUM(credits_attributed_compute) AS tag_query_attributed_credits,
    SUM(COALESCE(credits_used_query_acceleration, 0)) AS tag_qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE TO_DATE(start_time) >= (SELECT start_date FROM params)
    AND TO_DATE(start_time) <  (SELECT end_date   FROM params)
  GROUP BY 1, 2, 3
),

-- 3) Allocate idle credits back to tags proportionally to their query-attributed usage within each (d, warehouse)
alloc AS (
  SELECT
    t.d,
    t.warehouse_id,
    t.query_tag_norm,
    t.tag_query_attributed_credits,
    w.wh_idle_compute_credits,
    w.wh_query_attributed_credits,
    -- If wh_query_attributed_credits=0 (e.g., no attributable queries), allocate idle to a synthetic bucket
    CASE
      WHEN w.wh_query_attributed_credits > 0 THEN
        (t.tag_query_attributed_credits / w.wh_query_attributed_credits) * w.wh_idle_compute_credits
      ELSE 0
    END AS tag_idle_allocated_credits
  FROM tag_day t
  JOIN wh_day w
    ON t.d = w.d
   AND t.warehouse_id = w.warehouse_id
)

SELECT
  a.d,
  a.warehouse_id,
  a.query_tag_norm AS query_tag,
  a.tag_query_attributed_credits,
  a.tag_idle_allocated_credits,
  (a.tag_query_attributed_credits + a.tag_idle_allocated_credits) AS tag_total_compute_credits
FROM alloc a
ORDER BY a.d DESC, tag_total_compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes very short queries (<= ~100ms) and has lag (up to ~8h). | Daily “cost per team” may not match expectations for workloads dominated by short queries; dashboards may look “delayed.” | Compare `SUM(credits_attributed_compute)` vs `WAREHOUSE_METERING_HISTORY.credits_attributed_compute_queries` by hour/day; quantify delta and document. [2][3] |
| Idle-time allocation via proportional usage is a *policy choice* (not “the one true” chargeback). | Different stakeholders may dispute allocations. | Provide switchable policies: (a) allocate idle proportionally, (b) allocate to warehouse owner tag, (c) allocate to “unallocated/idle” bucket. [1][3] |
| Non-warehouse costs (cloud services billed, storage, serverless, AI tokens) are out-of-scope of this artifact. | “Total cost” views will be incomplete if we only use these three views. | Add separate pipelines for cloud services billed logic + serverless usage views; and/or use org currency views where available. [2][4] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Decide the Native App’s “idle cost” attribution policy set (proportional vs warehouse-owner vs unallocated bucket).
- Add a second artifact focusing on **object tags**: daily cost by `cost_center` tag on warehouses/users (via `TAG_REFERENCES`) for showback dashboards. [1]
- Explore org-level currency conversion options (`USAGE_IN_CURRENCY_DAILY`) and constraints (requires org account; edition requirements may apply). [4]
