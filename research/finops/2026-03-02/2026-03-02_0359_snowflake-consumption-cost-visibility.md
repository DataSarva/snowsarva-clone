# Research: FinOps - 2026-03-02

**Time:** 03:59 UTC  
**Topic:** Snowflake FinOps Cost Optimization (compute cost visibility + attribution primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credit usage per warehouse** (up to the last **365 days**) and includes total credits plus compute vs cloud-services components; the view has latency (up to ~3h; cloud services credits up to ~6h).  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY` view. [3]
2. Credit consumption shown in many views **does not account for the daily cloud services billing adjustment**; to determine **billed** credits for cloud services and compute, Snowflake recommends querying `METERING_DAILY_HISTORY`.  
   Source: Snowflake docs on exploring compute cost + metering daily history. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` provides query-history dimensions for the last **365 days**, including `QUERY_TAG` (for attribution), `WAREHOUSE_NAME`, and several performance/cost-relevant metrics (e.g., bytes scanned, queue times, compilation/execution time, cloud services credits).  
   Source: Snowflake docs for `QUERY_HISTORY` view. [4]
4. Snowflake cost-optimization guidance explicitly calls out **tagging at object level** (warehouses/users/etc.) and **query tagging** as core mechanisms for **granular cost attribution**, especially when warehouses are shared across teams/apps.  
   Source: Snowflake Well-Architected Framework (Cost Optimization pillar). [2]
5. Snowflake’s “Exploring compute cost” guide enumerates the canonical cost telemetry surfaces: hourly metering (`METERING_HISTORY`, `WAREHOUSE_METERING_HISTORY`), daily billed reconciliation (`METERING_DAILY_HISTORY`), and org-level conversion to currency (`USAGE_IN_CURRENCY_DAILY`). It also lists a dedicated view for **Native App** usage: `APPLICATION_DAILY_USAGE_HISTORY`.  
   Source: Snowflake docs on exploring compute cost. [1]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits for up to 365d; includes compute + cloud services; has latency; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for query-attributed compute (excludes idle). [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query history for up to 365d; contains `QUERY_TAG`, queue times, bytes scanned, `CREDITS_USED_CLOUD_SERVICES` (not adjusted for billing). [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily metering; used to compute **billed** cloud services credits due to 10% adjustment rule. Mentioned as reconciliation source. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by service type (warehouses/serverless/etc.); referenced as general cost view. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Converts credit usage to currency using daily price of a credit (org scope). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Daily credit usage for Snowflake Native Apps in an account (last 365d). [1] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution v1 (Query Tag + Warehouse):** Build a daily rollup table that attributes warehouse credits to `QUERY_TAG` using `QUERY_HISTORY` + `WAREHOUSE_METERING_HISTORY` (approximation), while separately tracking warehouse **idle credits** (compute idle = metering compute − attributed compute queries). This provides showback even when warehouses are shared.
2. **Billed vs Consumed Credits Reconciliation:** Add a “billed credits” panel that uses `METERING_DAILY_HISTORY` to compute cloud-services billing adjustments and present (a) consumed vs (b) billed credits at daily granularity.
3. **Native App (Consumer Account) Spend Baseline:** Surface `APPLICATION_DAILY_USAGE_HISTORY` as a first-class metric so the Native App can report “app-driven credits/day” alongside warehouse/serverless usage.

## Concrete Artifacts

### SQL Draft: Daily warehouse spend + idle cost + query-tag attribution (approx)

This draft creates a daily rollup with:
- warehouse daily credits
- idle compute credits estimate (per Snowflake example)
- per-query-tag approximate credits allocation for shared warehouses

```sql
-- Set UTC if you later reconcile with ORG_USAGE variants (per Snowflake note).
ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Warehouse daily totals + idle compute estimate
WITH wmh_daily AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used)                AS credits_used,
    SUM(credits_used_compute)        AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2
),
wmh_daily_enriched AS (
  SELECT
    usage_date,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS idle_compute_credits
  FROM wmh_daily
),

-- 2) Query-tag compute-seconds per warehouse per hour
-- We allocate warehouse hourly credits to query_tags in proportion to execution_time (ms).
-- This is an approximation (Snowflake provides a dedicated QUERY_ATTRIBUTION_HISTORY view;
-- but this draft stays on the minimal primitives covered in sources).
qh_hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '(none)') AS query_tag,
    SUM(execution_time) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND execution_time > 0
  GROUP BY 1,2,3
),
qh_hourly_totals AS (
  SELECT
    hour_start,
    warehouse_name,
    SUM(exec_ms) AS total_exec_ms
  FROM qh_hourly
  GROUP BY 1,2
),

-- 3) Hourly metering credits (warehouse) from WAREHOUSE_METERING_HISTORY itself
-- (since it is already hourly by definition)
wmh_hourly AS (
  SELECT
    start_time AS hour_start,
    warehouse_name,
    credits_used AS hour_credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
),

tag_alloc AS (
  SELECT
    TO_DATE(h.hour_start) AS usage_date,
    h.warehouse_name,
    h.query_tag,
    -- allocate hourly credits to tags
    (h.exec_ms / NULLIF(t.total_exec_ms, 0)) * m.hour_credits_used AS approx_credits_used
  FROM qh_hourly h
  JOIN qh_hourly_totals t
    ON t.hour_start = h.hour_start
   AND t.warehouse_name = h.warehouse_name
  JOIN wmh_hourly m
    ON m.hour_start = h.hour_start
   AND m.warehouse_name = h.warehouse_name
)

SELECT
  a.usage_date,
  a.warehouse_name,
  a.query_tag,
  SUM(a.approx_credits_used) AS approx_credits_used,
  w.credits_used             AS warehouse_credits_used_daily,
  w.idle_compute_credits      AS warehouse_idle_compute_credits_daily
FROM tag_alloc a
JOIN wmh_daily_enriched w
  ON w.usage_date = a.usage_date
 AND w.warehouse_name = a.warehouse_name
GROUP BY 1,2,3,5,6
ORDER BY 1 DESC, 2, 4 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| **Attribution approximation**: Allocating hourly warehouse credits to `QUERY_TAG` by `execution_time` is a heuristic. It won’t perfectly handle concurrency, multi-cluster behavior, cache effects, or non-query warehouse activity. | Misallocation across tags/teams; may create noisy showback. | Cross-check against Snowflake’s `QUERY_ATTRIBUTION_HISTORY` (not used in this minimal draft) and/or compare to known workload partitions. [1] mentions the view exists; add as v2. |
| Cloud services billing adjustment (10% rule) means “consumed” ≠ “billed”. | If we report spend purely from consumed credits, finance reconciliation will not match invoices. | Use `METERING_DAILY_HISTORY` as reconciliation source for billed cloud services credits. [1] |
| `ACCOUNT_USAGE` latency (hours) may make “near-real-time” dashboards misleading. | Users may overreact to partial-day data. | Annotate dashboards with freshness windows; optionally use Info Schema functions for shorter windows (but less history). [3][4] |
| Timezone differences between `ACCOUNT_USAGE` vs `ORG_USAGE` comparisons. | Misaligned day boundaries and incorrect org rollups. | Set session timezone to UTC before reconciling across schemas. [3] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Add a v2 attribution model that prefers `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` where available (compare with the heuristic allocation).
- Add a reconciliation job: daily `METERING_DAILY_HISTORY` → billed cloud services credits, plus “billed total credits” approximation.
- Decide how to handle **idle credits** in showback: allocate pro-rata by query tag, allocate to warehouse owner tag, or leave as an “unallocated/overhead” bucket.
