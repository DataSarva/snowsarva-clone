# Research: FinOps - 2026-03-03

**Time:** 23:01 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution via usage views + tags)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s recommended cost attribution approach is to use **object tags** to associate resources/users with cost centers and **query tags** to attribute queries when an application issues queries on behalf of multiple departments. [1]
2. For cost attribution **within a single account**, Snowflake points to these ACCOUNT_USAGE views: `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, and `QUERY_ATTRIBUTION_HISTORY`. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) but **excludes warehouse idle time** and has **latency up to ~8 hours**; short-running queries (≈<=100ms) are excluded. [3]
4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credits at the warehouse level** (compute + cloud services), includes a column for hourly credits attributed to queries (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`) and can be used to compute **idle cost** as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`. [4]
5. “Credits consumed” shown in many views include cloud services consumption that may not be billed; Snowflake notes cloud services usage is billed only when daily cloud services consumption exceeds **10%** of daily warehouse usage, and billed credits can be derived from `METERING_DAILY_HISTORY`. [2]
6. For organization-wide analytics, Snowflake exposes cost/usage views in `ORGANIZATION_USAGE` and recommends using `USAGE_IN_CURRENCY_DAILY` when you need currency amounts rather than credits. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Maps tags to objects (warehouses/users/etc); used for chargeback groupings. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (no idle). Latency up to ~3h (cloud services col up to ~6h). [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits (`CREDITS_ATTRIBUTED_COMPUTE`) + QAS credits; excludes idle time; latency up to ~8h; short queries excluded; columns available starting mid-Aug 2024 (older may be incomplete). [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily metering incl. cloud services adjustment for billed cloud services; referenced as the way to compute what was actually billed. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily credits converted to currency using daily credit price; org-wide. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Similar to account-level; Snowflake notes reconciliation requires session timezone set to UTC. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Chargeback dashboard v1 (credits + optional currency)**: daily and monthly cost by `cost_center`, broken down by: (a) dedicated warehouse costs (warehouse tagged), (b) shared-warehouse query costs by user tag, and (c) application query-tag costs. Uses only Snowflake-provided views + tags. [1][2][3][4]
2. **Idle-time “tax” visibility + allocation**: compute idle credits per warehouse, then either (a) report as “unallocated overhead”, or (b) allocate proportionally to departments based on their query-attributed credits (Snowflake provides examples of proportional idle allocation). [1][4]
3. **Tag coverage + hygiene checks**: alerts for (a) top spend in “untagged” bucket, (b) high spend from users without a `cost_center` tag, (c) missing query tags for known service principals/app roles.

## Concrete Artifacts

### SQL Draft: Daily cost attribution by cost_center (warehouse tags + user tags + query tags) + idle allocation

**Goal:** produce a single daily table for FinOps reporting:
- `compute_credits_total` = warehouse compute credits (truth source)
- `query_credits_attributed` = sum of `QUERY_ATTRIBUTION_HISTORY` credits (excludes idle)
- `idle_credits` = remaining compute credits
- allocate idle credits **proportionally** by cost center (optional; default shown)

```sql
-- COST ATTRIBUTION DAILY (ACCOUNT-LEVEL)
-- Notes:
-- 1) QUERY_ATTRIBUTION_HISTORY excludes idle time. [3]
-- 2) Idle credits can be computed from WAREHOUSE_METERING_HISTORY as
--    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries). [4]
-- 3) This draft focuses on warehouse compute credits; cloud services billed-ness is separate. [2]

-- Parameters
SET start_date = DATEADD('day', -30, CURRENT_DATE());
SET end_date   = CURRENT_DATE();

WITH
-- 1) Hourly warehouse compute credits (truth source)
wh_hour AS (
  SELECT
    TO_DATE(start_time)                  AS usage_date,
    warehouse_id,
    warehouse_name,
    credits_used_compute                 AS wh_compute_credits,
    credits_attributed_compute_queries   AS wh_query_attributed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_date
    AND start_time <  $end_date
    AND warehouse_id > 0  -- exclude pseudo warehouses like CLOUD_SERVICES_ONLY (per docs examples) [2]
),

-- 2) Per-query attributed credits, bucketed daily and by cost_center via:
--    (a) query_tag when present (app/workflow attribution) [1][3]
--    (b) else user object tag (shared resources scenario) [1]
q_cost AS (
  SELECT
    TO_DATE(qah.start_time) AS usage_date,
    qah.warehouse_id,
    qah.query_id,
    qah.user_name,
    qah.query_tag,
    qah.credits_attributed_compute AS query_credits,

    -- Priority: query_tag encodes COST_CENTER=... (convention) else user tag
    COALESCE(
      NULLIF(REGEXP_SUBSTR(qah.query_tag, 'COST_CENTER=([^;\s]+)', 1, 1, 'e', 1), ''),
      COALESCE(utr.tag_value, 'untagged')
    ) AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES utr
    ON utr.domain = 'USER'
   AND utr.object_name = qah.user_name
   AND utr.tag_name = 'COST_CENTER'
  WHERE qah.start_time >= $start_date
    AND qah.start_time <  $end_date
),

-- 3) Aggregate per day/warehouse/cost_center
cc_day AS (
  SELECT
    usage_date,
    warehouse_id,
    cost_center,
    SUM(query_credits) AS query_credits_attributed
  FROM q_cost
  GROUP BY 1,2,3
),

-- 4) Warehouse daily totals + idle credits
wh_day AS (
  SELECT
    usage_date,
    warehouse_id,
    ANY_VALUE(warehouse_name) AS warehouse_name,
    SUM(wh_compute_credits) AS wh_compute_credits,
    SUM(wh_query_attributed_credits) AS wh_query_attributed_credits,
    (SUM(wh_compute_credits) - SUM(wh_query_attributed_credits)) AS idle_credits
  FROM wh_hour
  GROUP BY 1,2
),

-- 5) Allocate idle credits proportionally by cost_center share of query_credits_attributed
alloc AS (
  SELECT
    c.usage_date,
    c.warehouse_id,
    c.cost_center,
    c.query_credits_attributed,
    w.wh_compute_credits,
    w.idle_credits,

    CASE
      WHEN SUM(c.query_credits_attributed) OVER (PARTITION BY c.usage_date, c.warehouse_id) = 0 THEN 0
      ELSE
        (c.query_credits_attributed
          / SUM(c.query_credits_attributed) OVER (PARTITION BY c.usage_date, c.warehouse_id)
        ) * w.idle_credits
    END AS idle_credits_allocated
  FROM cc_day c
  JOIN wh_day w
    ON w.usage_date = c.usage_date
   AND w.warehouse_id = c.warehouse_id
)

SELECT
  usage_date,
  warehouse_id,
  cost_center,
  query_credits_attributed,
  idle_credits_allocated,
  (query_credits_attributed + idle_credits_allocated) AS compute_credits_total_attributed
FROM alloc
ORDER BY usage_date DESC, compute_credits_total_attributed DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assumes a convention like `QUERY_TAG` contains `COST_CENTER=<value>` for app-issued queries. | If query tags use a different format, attribution falls back to user tags and may mis-attribute app workloads. | Confirm org’s query-tagging standard and update parser; possibly map `query_tag` to cost center via a managed lookup table. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short-running queries (≈<=100ms). | Total by cost center won’t reconcile to warehouse compute credits without an idle allocation strategy; high-throughput workloads may be underrepresented. | Reconcile daily totals to `WAREHOUSE_METERING_HISTORY` and decide: show idle as overhead vs allocate proportionally. [3][4] |
| View latencies differ (WAREHOUSE_METERING_HISTORY up to ~3h, QUERY_ATTRIBUTION_HISTORY up to ~8h). | “Today” dashboards can look inconsistent/incomplete for several hours. | Use a watermark (e.g., only finalize days older than N hours) and annotate freshness. [3][4] |
| Cloud services credits may not be billed unless they exceed the daily 10% threshold; many views show consumed credits not billed credits. | Chargeback in currency can be wrong if you treat consumed cloud services as billed. | Use `METERING_DAILY_HISTORY` and/or currency views (`USAGE_IN_CURRENCY_DAILY`) for billed-aligned reporting. [2] |
| Organization-wide equivalents vary; Snowflake notes `QUERY_ATTRIBUTION_HISTORY` is account-scoped in their cost-attribution guide, while separate org-level docs exist for org usage premium views. | Cross-account query-level attribution may require org account + edition constraints and/or different views. | Confirm edition + availability in org account; test access to `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` if needed. [1][3] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Decide product stance: treat idle credits as (a) overhead (unallocated) vs (b) allocate proportionally (default in Snowflake examples). [1][4]
- Add a “freshness window” rule for dashboards due to view latency differences; e.g. only show finalized data up to `CURRENT_TIMESTAMP - INTERVAL '10 hours'`. [3][4]
- If we need currency-level chargeback, incorporate org-level `USAGE_IN_CURRENCY_DAILY` and document how it reconciles to consumed credits, especially cloud services billing adjustments. [2]
