# Research: FinOps - 2026-03-04

**Time:** 05:47 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** (plus optional query acceleration credits) but **excludes warehouse idle time**, and **excludes very short-running queries (~<=100ms)**. Latency can be **up to 8 hours**.  
   Source: Snowflake docs (`QUERY_ATTRIBUTION_HISTORY` view) https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history

2. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` records **direct object↔tag associations only**; it **does not include inherited tags**. Latency can be **up to 120 minutes** and the view only shows objects your current role can see.  
   Source: Snowflake docs (`TAG_REFERENCES` view) https://docs.snowflake.com/en/sql-reference/account-usage/tag_references

3. Snowflake’s recommended approach for cost attribution is:
   - use **object tags** to associate resources/users with a cost center
   - use **query tags** when an app runs queries on behalf of users from multiple cost centers
   - join `TAG_REFERENCES` with `WAREHOUSE_METERING_HISTORY` (warehouse-level) and/or `QUERY_ATTRIBUTION_HISTORY` (query-level) for analysis in SQL
   - there is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY` in `ORGANIZATION_USAGE`.
   Source: Snowflake docs (“Attributing cost”) https://docs.snowflake.com/en/user-guide/cost-attributing

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Query-level compute credits attributed; excludes idle time; excludes ~<=100ms queries; up to 8h latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag bindings only (no inheritance); up to 120m latency; filtered by role access. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Warehouse-hour compute credits metered; used to reconcile to billed warehouse compute and to allocate idle. (Mentioned in cost-attributing doc; not extracted today.) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Attribution coverage + freshness” dashboard metric**: show last data timestamp per source (`TAG_REFERENCES` up to 2h; `QUERY_ATTRIBUTION_HISTORY` up to 8h) and coverage ratios (tagged warehouses/users vs total). This prevents support tickets caused by users expecting real-time.

2. **Two-lane cost model (Attribution vs. Reconciliation)**:
   - Lane A: “attributed compute” from `QUERY_ATTRIBUTION_HISTORY` (fast, query-granular)
   - Lane B: “metered compute” from `WAREHOUSE_METERING_HISTORY` (reconciliation truth)
   Then compute an “idle/unattributed delta” per warehouse-hour for FinOps workflows.

3. **Tag quality linting job**: detect where cost center tags are missing or inconsistent using `TAG_REFERENCES` (direct bindings), and publish a fix-it report (e.g., untagged warehouses/users, deprecated tag values, objects dropped but still referenced historically).

## Concrete Artifacts

### SQL draft: Daily cost attribution rollup (query-tag lane + object-tag lane)

Goal: produce a daily table that supports:
- cost by `QUERY_TAG` (app-provided attribution)
- cost by `COST_CENTER` object tags on users/warehouses
- a reconciliation metric to highlight idle/unattributed warehouse credits

```sql
-- MC_COST_ATTRIBUTION_DAILY.sql
-- Assumptions:
-- 1) You tag USERS and/or WAREHOUSES with cost center using an object tag like COST_MANAGEMENT.TAGS.COST_CENTER.
-- 2) Apps optionally set QUERY_TAG (e.g. 'COST_CENTER=finance') for shared-warehouse workloads.
-- 3) QUERY_ATTRIBUTION_HISTORY excludes idle time; we reconcile against WAREHOUSE_METERING_HISTORY.
--
-- Notes:
-- - TAG_REFERENCES contains direct bindings only (no inheritance).
-- - Source latencies: TAG_REFERENCES up to ~120m; QUERY_ATTRIBUTION_HISTORY up to ~8h.

CREATE OR REPLACE TABLE FINOPS.MART.MC_COST_ATTRIBUTION_DAILY AS
WITH
params AS (
  SELECT
    DATEADD('day', -30, CURRENT_DATE()) AS start_date,
    CURRENT_DATE() AS end_date
),

-- 1) Object tag bindings (direct only)
user_cost_center AS (
  SELECT
    tr.object_name      AS user_name,
    tr.tag_value        AS cost_center
  FROM snowflake.account_usage.tag_references tr
  WHERE tr.domain = 'USER'
    AND tr.tag_name = 'COST_CENTER'
    AND tr.object_deleted IS NULL
),

warehouse_cost_center AS (
  SELECT
    tr.object_id        AS warehouse_id,
    tr.tag_value        AS cost_center
  FROM snowflake.account_usage.tag_references tr
  WHERE tr.domain = 'WAREHOUSE'
    AND tr.tag_name = 'COST_CENTER'
    AND tr.object_deleted IS NULL
),

-- 2) Query-level attributed compute (excludes idle)
q_attr AS (
  SELECT
    DATE_TRUNC('day', qah.start_time) AS usage_date,
    qah.warehouse_id,
    qah.user_name,
    COALESCE(NULLIF(qah.query_tag, ''), 'untagged') AS query_tag,
    SUM(qah.credits_attributed_compute) AS credits_attrib_compute,
    SUM(COALESCE(qah.credits_used_query_acceleration, 0)) AS credits_qas
  FROM snowflake.account_usage.query_attribution_history qah
  JOIN params p
    ON qah.start_time >= p.start_date
   AND qah.start_time <  p.end_date
  GROUP BY 1,2,3,4
),

-- 3) Warehouse metering truth (includes idle)
wh_meter AS (
  SELECT
    DATE_TRUNC('day', wmh.start_time) AS usage_date,
    wmh.warehouse_id,
    SUM(wmh.credits_used_compute) AS credits_metered_compute
  FROM snowflake.account_usage.warehouse_metering_history wmh
  JOIN params p
    ON wmh.start_time >= p.start_date
   AND wmh.start_time <  p.end_date
  GROUP BY 1,2
),

-- 4) Aggregate query attribution by warehouse-day for reconciliation
q_attr_wh_day AS (
  SELECT
    usage_date,
    warehouse_id,
    SUM(credits_attrib_compute) AS credits_attrib_compute_wh_day
  FROM q_attr
  GROUP BY 1,2
)

SELECT
  -- grain: (day, warehouse, attribution dimension)
  q.usage_date,
  q.warehouse_id,

  -- attribution lanes
  q.query_tag,
  COALESCE(ucc.cost_center, wcc.cost_center, 'untagged') AS object_cost_center,

  -- measures
  q.credits_attrib_compute,
  q.credits_qas,

  -- reconciliation: warehouse metered credits vs total attributed credits
  wm.credits_metered_compute,
  qwh.credits_attrib_compute_wh_day,
  (wm.credits_metered_compute - qwh.credits_attrib_compute_wh_day) AS credits_idle_or_unattributed_wh_day

FROM q_attr q
LEFT JOIN user_cost_center ucc
  ON q.user_name = ucc.user_name
LEFT JOIN warehouse_cost_center wcc
  ON q.warehouse_id = wcc.warehouse_id
LEFT JOIN wh_meter wm
  ON q.usage_date = wm.usage_date
 AND q.warehouse_id = wm.warehouse_id
LEFT JOIN q_attr_wh_day qwh
  ON q.usage_date = qwh.usage_date
 AND q.warehouse_id = qwh.warehouse_id
;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES` does not include inherited tags. | Cost center attribution may look “missing” if a user expects inheritance behavior. | Confirm whether org relies on inheritance; if yes, must additionally query tag lineage/propagation views or enforce direct tags for FinOps dimensions. (Docs explicitly state no inheritance in `TAG_REFERENCES`.) https://docs.snowflake.com/en/sql-reference/account-usage/tag_references |
| Query cost attribution excludes idle and ~<=100ms queries. | Rollups will not match metered compute unless you explicitly model the delta. | Use reconciliation vs `WAREHOUSE_METERING_HISTORY` and show “idle/unattributed delta”. (Docs state exclusions.) https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history |
| Data freshness: QAH up to 8h latency; tags up to 2h latency. | Near-real-time dashboards/alerts will be misleading. | Publish freshness watermark metrics + avoid “today” alerts until watermark passes. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history and https://docs.snowflake.com/en/sql-reference/account-usage/tag_references |
| No `ORGANIZATION_USAGE` equivalent of QAH. | Cross-account query-level attribution must be computed per account or via ingestion into a central org account. | Documented in cost attribution guide. https://docs.snowflake.com/en/user-guide/cost-attributing |

## Links & Citations

1. Snowflake docs: Attributing cost (tags + views; no org-wide `QUERY_ATTRIBUTION_HISTORY`) https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: `QUERY_ATTRIBUTION_HISTORY` view (columns, exclusions, 8h latency) https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake docs: `TAG_REFERENCES` view (direct bindings only; no inheritance; 120m latency) https://docs.snowflake.com/en/sql-reference/account-usage/tag_references

## Next Steps / Follow-ups

- Verify what view(s) Snowflake provides for *inherited* tag relationships / propagation, and whether we need to model inheritance explicitly or require direct tagging for FinOps dimensions.
- Extend the SQL draft into a Native App-friendly data product: incremental loads, late-arriving data handling (8h/2h), and secure-by-default access patterns (roles with `USAGE_VIEWER` / `GOVERNANCE_VIEWER` where required).
