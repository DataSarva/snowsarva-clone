# Research: FinOps - 2026-02-28

**Time:** 13:18 UTC  
**Topic:** Snowflake FinOps Cost Optimization (per-query attribution vs warehouse metering; handling idle)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides *per-query* **compute** credits attributed to queries executed on warehouses in the last **365 days**; it **excludes warehouse idle time** and excludes other credit categories (e.g., serverless features, storage, data transfer, cloud services, AI token costs). It also omits **very short-running queries** (<= ~100ms). Latency can be up to **8 hours**. 
2. For showback/chargeback, Snowflake’s recommended primitives are: `ACCOUNT_USAGE.TAG_REFERENCES` (which objects have tags), `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly warehouse credits), and `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute credits). These can be joined/aggregated to attribute cost by tag (object tags) and by `QUERY_TAG` (session query tag).
3. There is an inherent reconciliation gap between (a) warehouse-hour credits billed in `WAREHOUSE_METERING_HISTORY` and (b) sum of query-attributed credits in `QUERY_ATTRIBUTION_HISTORY` because the latter excludes **idle time**; if you want “all-in warehouse compute allocation by tag/query_tag”, you need an **idle allocation rule** (e.g., allocate hourly idle proportionally to the hour’s query-attributed credits, or attribute idle to a specific “platform” cost center).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits; excludes idle; <=~100ms queries omitted; latency up to ~8 hours; 365d retention. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (includes billed compute per hour). Useful for reconciling and allocating idle at warehouse-hour grain. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to objects (WAREHOUSE / USER / DB / SCHEMA / etc) via `domain`, `object_id`, `object_name`, `tag_name`, `tag_value`. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level metadata including `QUERY_TAG` (but *not* authoritative for per-query credits). Useful for enriching dimensions. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Cost allocation “reconciliation mode” toggle**: show two numbers for any grouping (team/tag/query_tag):
   - *Attributed query compute (ex-idle)* from `QUERY_ATTRIBUTION_HISTORY`.
   - *Allocated warehouse compute (incl. idle)* by allocating warehouse-hour idle deltas from `WAREHOUSE_METERING_HISTORY`.
2. **Tag hygiene dashboard**: list top spend where the grouping key is missing (e.g., `QUERY_TAG` empty/NULL → “untagged”; warehouses/users without `cost_center` tag using `TAG_REFERENCES`).
3. **Stored-procedure / DAG cost rollup**: use `ROOT_QUERY_ID` / `PARENT_QUERY_ID` columns in `QUERY_ATTRIBUTION_HISTORY` to sum a procedure’s total attributed compute (useful for orchestrators and “unit cost per run”).

## Concrete Artifacts

### SQL Draft: Allocate warehouse-hour compute (incl. idle) to `QUERY_TAG`

Goal: compute monthly credits by `QUERY_TAG`, including an *idle allocation* so totals reconcile to warehouse-hour credits.

Assumptions (explicit):
- We allocate idle per **warehouse-hour** proportionally to the sum of query-attributed credits in that same warehouse-hour.
- If a warehouse-hour has *no* attributed queries (e.g., only <=~100ms queries, or pure idle), we attribute the entire hour to `__unattributed_idle__`.

```sql
-- Allocate warehouse-hour credits to query_tag.
-- Sources:
--   - ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (per-query compute credits, ex-idle)
--   - ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly warehouse credits)
-- Notes:
--   - Latency: up to ~8 hours on QUERY_ATTRIBUTION_HISTORY.
--   - This draft focuses on compute credits; extend similarly for other cost dimensions.

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS month_start,
    CURRENT_DATE() AS month_end
),

-- 1) Warehouse-hour billed compute credits
wh_hour AS (
  SELECT
    warehouse_id,
    warehouse_name,
    DATE_TRUNC('HOUR', start_time) AS hour_start,
    SUM(credits_used_compute) AS wh_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= (SELECT month_start FROM params)
    AND start_time <  (SELECT month_end   FROM params)
  GROUP BY 1,2,3
),

-- 2) Query-attributed credits at warehouse-hour + query_tag grain
qah_hour_tag AS (
  SELECT
    warehouse_id,
    warehouse_name,
    DATE_TRUNC('HOUR', start_time) AS hour_start,
    COALESCE(NULLIF(query_tag, ''), '__untagged__') AS query_tag,
    SUM(credits_attributed_compute) AS attributed_compute_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= (SELECT month_start FROM params)
    AND start_time <  (SELECT month_end   FROM params)
  GROUP BY 1,2,3,4
),

-- 3) Total query-attributed credits per warehouse-hour (denominator for idle allocation)
qah_hour_total AS (
  SELECT
    warehouse_id,
    warehouse_name,
    hour_start,
    SUM(attributed_compute_credits) AS attributed_total
  FROM qah_hour_tag
  GROUP BY 1,2,3
),

-- 4) Join to compute idle delta per warehouse-hour
recon AS (
  SELECT
    w.warehouse_id,
    w.warehouse_name,
    w.hour_start,
    w.wh_compute_credits,
    COALESCE(t.attributed_total, 0) AS attributed_total,
    GREATEST(w.wh_compute_credits - COALESCE(t.attributed_total, 0), 0) AS idle_delta
  FROM wh_hour w
  LEFT JOIN qah_hour_total t
    ON w.warehouse_id = t.warehouse_id
   AND w.hour_start   = t.hour_start
)

-- 5) Allocate idle_delta proportionally across query_tags within the same warehouse-hour
SELECT
  r.warehouse_name,
  r.hour_start,
  q.query_tag,
  q.attributed_compute_credits,
  CASE
    WHEN r.attributed_total > 0
      THEN q.attributed_compute_credits + (q.attributed_compute_credits / r.attributed_total) * r.idle_delta
    ELSE 0
  END AS allocated_compute_credits_incl_idle
FROM recon r
JOIN qah_hour_tag q
  ON r.warehouse_id = q.warehouse_id
 AND r.hour_start   = q.hour_start

UNION ALL

-- 6) If an hour has no attributed queries, bucket the whole warehouse-hour into an explicit idle category
SELECT
  r.warehouse_name,
  r.hour_start,
  '__unattributed_idle__' AS query_tag,
  0 AS attributed_compute_credits,
  r.wh_compute_credits AS allocated_compute_credits_incl_idle
FROM recon r
WHERE r.attributed_total = 0
;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Idle allocation policy is organization-dependent (proportional vs “platform” cost center vs last-query-wins). | Different teams will dispute fairness; dashboards can drive behavior. | Confirm desired accounting policy with Akhil / finance stakeholders; implement as a configurable policy in-app. |
| `QUERY_ATTRIBUTION_HISTORY` excludes <=~100ms queries and can lag up to ~8 hours. | Some workloads may appear “missing” or delayed; reconciliation deltas may spike. | Run daily reconciliation report: warehouse-hour billed vs sum(attributed); inspect warehouses with large deltas and correlate with short-query patterns. |
| `QUERY_ATTRIBUTION_HISTORY` covers compute only (not serverless/AI/storage/transfer). | “Total cost” KPIs will be incomplete if we present them as all-in. | Present compute-only clearly; add separate modules for `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, data transfer, AI usage history views as separate lines. |

## Links & Citations

1. Snowflake Docs — Attributing cost (views used + examples joining TAG_REFERENCES, WAREHOUSE_METERING_HISTORY, QUERY_ATTRIBUTION_HISTORY): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view (365d, excludes idle, <=~100ms queries omitted, latency up to 8 hours): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Developers — Well-Architected Framework: Cost Optimization & FinOps (recommends tags + using TAG_REFERENCES with usage views): https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
4. Snowflake Release Notes — Per-query cost attribution (launch of query attribution costs): https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution

## Next Steps / Follow-ups

- Extend the SQL draft to allocate by **object tags** (e.g., warehouse tag `cost_center`) by joining `TAG_REFERENCES` on `WAREHOUSE_ID` + `domain='WAREHOUSE'`.
- Add a second allocation path for **user-tag-based attribution** (`domain='USER'`, join via `object_name = user_name`) for shared warehouses.
- Decide and document (ADR) the default **idle allocation policy** and expose it as an app setting.
