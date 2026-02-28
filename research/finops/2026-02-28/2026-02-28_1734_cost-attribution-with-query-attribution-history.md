# Research: FinOps - 2026-02-28

**Time:** 17:34 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is to use **object tags** to associate resources/users with cost owners, and **query tags** when the same application issues queries on behalf of multiple departments. (Cost attribution guide)  
2. For SQL-based attribution **within an account**, Snowflake documentation explicitly calls out using `SNOWFLAKE.ACCOUNT_USAGE` views: `TAG_REFERENCES` (tagged objects), `WAREHOUSE_METERING_HISTORY` (warehouse credit usage), and `QUERY_ATTRIBUTION_HISTORY` (compute cost attributed to queries). (Cost attribution guide)  
3. `QUERY_ATTRIBUTION_HISTORY` provides **compute credits attributed to individual queries** for the last 365 days, but **does not include warehouse idle time**. The cost per query also **excludes** data transfer, storage, cloud services, serverless features, and AI token costs. (Cost attribution guide)  
4. `TAG_REFERENCES` records only **direct** tag-to-object relationships; **tag inheritance is not included**. Latency can be **up to 120 minutes** and results depend on the current role’s privileges. (TAG_REFERENCES view)  
5. `WAREHOUSE_METERING_HISTORY` returns **hourly** warehouse credit usage for the last 365 days. In `ACCOUNT_USAGE`, latency is up to **180 minutes** (and cloud-services credits can lag up to **6 hours**). It includes a column for credits attributed to queries (excluding idle time), and provides an example for estimating idle-time cost. (WAREHOUSE_METERING_HISTORY view)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag relationships only (no inheritance). Up to ~120 min latency; privilege-filtered. Useful join key: `OBJECT_ID`/`OBJECT_NAME` + `DOMAIN`. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (`CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`). Up to ~3h latency (cloud services up to ~6h). Has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle time). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed compute credits. Excludes idle time and multiple non-compute cost categories. Supports grouping by `QUERY_HASH` / `QUERY_PARAMETERIZED_HASH` for recurring query families. |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` (e.g., `WAREHOUSE_METERING_HISTORY`, `TAG_REFERENCES`) | Views | `ORG_USAGE` | Used to attribute across accounts (from the org account). Docs note there is **no org-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`. (So per-query compute attribution is account-scoped.) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution “Mart” (daily)**: build a daily table (or dynamic table) that allocates warehouse compute credits to **cost centers** using object tags (warehouses/users) and query tags, with an explicit **idle-time allocation policy** (proportional vs unallocated bucket).
2. **Coverage & Hygiene**: a FinOps “tag coverage” scorecard using `TAG_REFERENCES` (direct tags) to detect untagged warehouses/users and show which domains lack required tags.
3. **Top Expensive Query Families**: compute `QUERY_PARAMETERIZED_HASH` rollups from `QUERY_ATTRIBUTION_HISTORY` for “most expensive recurring workloads” and attach recommended controls (warehouse sizing, clustering, caching, query rewrite).

## Concrete Artifacts

### SQL draft: daily compute credits by cost center (warehouse tags + idle-time allocation)

This follows Snowflake’s documented join pattern between `WAREHOUSE_METERING_HISTORY` and `TAG_REFERENCES` and then distributes warehouse idle compute to cost centers proportionally to query-attributed compute.

```sql
-- Goal: attribute warehouse compute credits to COST_CENTER tag values.
-- Sources:
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--   - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
--   - SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- Notes:
--   - QUERY_ATTRIBUTION_HISTORY excludes idle time; we allocate idle time proportionally.
--   - TAG_REFERENCES does NOT include tag inheritance.

-- Required session settings if you later reconcile ACCOUNT_USAGE vs ORG_USAGE:
-- ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_hourly AS (
  SELECT
    DATE_TRUNC('HOUR', start_time) AS hour_start,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
),

-- cost_center by warehouse (direct tag on warehouse)
wh_cost_center AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
    AND tag_name ILIKE 'COST_CENTER'
),

-- per-hour query-attributed compute by warehouse + query_tag (optional dimension)
qah_hourly AS (
  SELECT
    DATE_TRUNC('HOUR', start_time) AS hour_start,
    warehouse_id,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS qah_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
),

-- join everything; allocate idle compute proportionally to qah_credits
alloc AS (
  SELECT
    w.hour_start,
    w.warehouse_id,
    w.warehouse_name,
    COALESCE(cc.cost_center, 'untagged') AS cost_center,
    q.query_tag,

    -- base measures
    w.credits_used_compute AS wh_compute_credits,
    COALESCE(q.qah_credits, 0) AS query_attrib_credits,

    -- idle compute = warehouse compute - sum(query attributed)
    GREATEST(
      w.credits_used_compute - COALESCE(w.credits_attributed_compute_queries, 0),
      0
    ) AS wh_idle_compute_credits
  FROM wh_hourly w
  LEFT JOIN wh_cost_center cc
    ON w.warehouse_id = cc.warehouse_id
  LEFT JOIN qah_hourly q
    ON w.hour_start = q.hour_start
   AND w.warehouse_id = q.warehouse_id
),

-- total query-attrib credits per warehouse-hour for proportional allocation
denom AS (
  SELECT
    hour_start,
    warehouse_id,
    SUM(query_attrib_credits) AS total_query_attrib
  FROM alloc
  GROUP BY 1,2
)

SELECT
  a.hour_start,
  a.cost_center,
  a.warehouse_name,
  a.query_tag,

  -- allocate idle proportionally; if no queries, put idle into an 'idle-unallocated' bucket
  CASE
    WHEN d.total_query_attrib > 0
      THEN a.query_attrib_credits + (a.query_attrib_credits / d.total_query_attrib) * a.wh_idle_compute_credits
    WHEN a.query_tag = 'untagged'
      THEN a.wh_compute_credits
    ELSE 0
  END AS attributed_compute_credits

FROM alloc a
JOIN denom d
  ON a.hour_start = d.hour_start
 AND a.warehouse_id = d.warehouse_id;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tag inheritance not present in `ACCOUNT_USAGE.TAG_REFERENCES` | Under-attribution if you rely on propagated/inherited tag semantics | Compare with information schema table function `TAG_REFERENCES` for inherited associations; document expected tagging policy. (TAG_REFERENCES doc explicitly says “direct only”.) |
| `QUERY_ATTRIBUTION_HISTORY` excludes non-compute categories (cloud services, storage, serverless, etc.) | “Total cost” dashboards will not reconcile to invoices unless you separately model those cost categories | Combine with other billing/metering views (e.g., daily metering) and explicitly label “compute-only attribution” vs “total cost”. |
| View latency (120–360 min depending on view/column) | Near-real-time FinOps alerts can be wrong or delayed | Use materialization with backfill windows and freshness checks; annotate dashboards with “data as-of” timestamps. |
| No organization-wide equivalent of `QUERY_ATTRIBUTION_HISTORY` | Multi-account FinOps needs per-account pipelines for query-level attribution | Architect the native app to run per consumer account and optionally aggregate to org account at a coarser granularity (warehouse-level). |

## Links & Citations

1. Snowflake docs: **Attributing cost** (includes recommended approach + views used; notes org-wide limitations; includes SQL examples)  
   https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake reference: **TAG_REFERENCES (ACCOUNT_USAGE)** (direct-only, no inheritance; latency notes; privilege filtering)  
   https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
3. Snowflake reference: **WAREHOUSE_METERING_HISTORY (ACCOUNT_USAGE)** (hourly usage; column meanings; latency notes; idle-time example)  
   https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. Snowflake reference: **QUERY_ATTRIBUTION_HISTORY (ACCOUNT_USAGE)** (per-query compute credits; columns like `QUERY_PARAMETERIZED_HASH`, `QUERY_TAG`)  
   https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
5. Snowflake Well-Architected guide: **Cost Optimization & FinOps** (recommends tags and joining `TAG_REFERENCES` with usage views for attribution)  
   https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Confirm what “total cost reconciliation” should mean for the Native App MVP (compute-only vs compute+cloud-services vs full invoice categories).
- Add a small ADR in the repo for the **idle-time allocation policy** (proportional allocation vs explicit idle bucket) and its implications for chargeback fairness.
- Expand the attribution model to include **query-acceleration** credits (`credits_used_query_acceleration`) surfaced in the cost attribution guide examples.
