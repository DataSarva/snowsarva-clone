# Research: FinOps - 2026-03-04

**Time:** 11:59 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including separate columns for compute vs cloud services credits; however, `CREDITS_USED` in this view **does not** apply the daily cloud services billing adjustment and can exceed billed credits. To determine **billed** credits, Snowflake directs you to use `METERING_DAILY_HISTORY`.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` returns **daily** billed credit usage for the last **365 days**, including `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative) and `CREDITS_BILLED` (compute + cloud services + adjustment). It also breaks usage out by `SERVICE_TYPE` (warehouses, serverless features, AI services, etc.).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` represents credits attributed to query execution only and **excludes warehouse idle time**; Snowflake provides an example of computing idle cost as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

4. Resource Monitors can help control costs for **warehouses** and can suspend user-managed warehouses at thresholds, but they **cannot** track spending associated with **serverless features and AI services**; Snowflake recommends budgets for those. Resource monitor evaluation uses cloud services consumption for thresholds and does not incorporate the daily cloud services billing adjustment.  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors

5. `SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY` provides average daily database storage usage (including time travel and fail-safe bytes) for the last **365 days**; Snowflake recommends setting timezone to UTC for reconciliation and notes new columns tied to behavior change bundle `2025_07`.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/database_storage_usage_history

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits by warehouse; `CREDITS_USED` may exceed billed; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for query-attributed compute (idle excluded). Latency up to ~3h; cloud services column up to 6h. |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Daily billed credits; includes cloud services adjustment + `CREDITS_BILLED`. Latency up to ~3h. Includes `SERVICE_TYPE` for non-warehouse spend categories. |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY | View | ACCOUNT_USAGE | Query metadata (warehouse, role, tag, timings, bytes scanned, etc.). Does not directly provide per-query credits; includes `query_tag` for app-driven attribution. |
| SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY | View | ACCOUNT_USAGE | Daily average storage bytes per database; includes fail-safe. Notes BCR 2025_07 adds SLP columns if bundle enabled. |
| RESOURCE MONITOR (object) | Object | N/A (DDL) | Warehouse-only credit controls; not for serverless/AI services; thresholds include cloud services usage not adjusted for billing. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Billed vs metered” reconciliation tile**: show daily `CREDITS_BILLED` (truth for billing) side-by-side with summed hourly `WAREHOUSE_METERING_HISTORY.CREDITS_USED` (useful for operational/hourly analysis), with an explicit warning that hourly totals won’t reconcile due to cloud services adjustment.

2. **Idle-cost leaderboard per warehouse**: compute and display `idle_credits = credits_used_compute - credits_attributed_compute_queries` by warehouse and time window (e.g., last 7/30 days). This is directly supported by Snowflake’s own example query.

3. **Service-type spend breakdown**: use `METERING_DAILY_HISTORY.SERVICE_TYPE` to expose non-warehouse cost categories (serverless + AI services) that Resource Monitors cannot enforce, so the app can recommend budgets/policies and alerting for those categories.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Daily billed credits vs hourly metered credits (warehouse) + idle credits

Goal: produce a daily fact table that:
- uses `METERING_DAILY_HISTORY` as the *billed* source of truth (daily)
- uses `WAREHOUSE_METERING_HISTORY` for operational breakdowns (hourly/warehouse)
- computes idle credits at the warehouse level

```sql
-- FACT: daily billed credits by service type (billing truth)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- Note: this view is daily and already includes cloud services adjustment in CREDITS_BILLED.

WITH billed AS (
  SELECT
    usage_date,
    service_type,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_adjustment_cloud_services) AS credits_adjustment_cloud_services,
    SUM(credits_billed) AS credits_billed
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1,2
),

-- FACT: daily warehouse metering rollups (operational, may not reconcile to billed)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
warehouse_daily AS (
  SELECT
    CAST(start_time AS DATE) AS usage_date,
    warehouse_name,
    SUM(credits_used_compute) AS wh_credits_used_compute,
    SUM(credits_used_cloud_services) AS wh_credits_used_cloud_services,
    SUM(credits_used) AS wh_credits_used_total,
    -- Query-attributed compute credits (excludes idle)
    SUM(credits_attributed_compute_queries) AS wh_credits_attributed_compute_queries,
    -- Snowflake-documented idle cost calculation
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS wh_idle_credits_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
    AND end_time < CURRENT_DATE()
  GROUP BY 1,2
)

SELECT
  b.usage_date,
  b.service_type,
  b.credits_billed,
  b.credits_used_compute,
  b.credits_used_cloud_services,
  b.credits_adjustment_cloud_services,
  wd.warehouse_name,
  wd.wh_credits_used_total,
  wd.wh_idle_credits_compute
FROM billed b
LEFT JOIN warehouse_daily wd
  ON wd.usage_date = b.usage_date
  AND b.service_type IN ('WAREHOUSE_METERING','WAREHOUSE_METERING_READER');
```

### Artifact: (Design sketch) Query-tag-based cost attribution model

Constraint: `QUERY_HISTORY` does not provide per-query credits directly. But the app can still:
- enforce and standardize `QUERY_TAG` usage to attribute workload to apps/teams/env
- allocate query-attributed warehouse credits within an hour/day using a proportional heuristic

Heuristic proposal (explicitly labeled as approximate):
- per (warehouse, hour): take `credits_attributed_compute_queries` as the “query execution credits budget”
- allocate to individual queries in that hour proportionally by `execution_time` (or `total_elapsed_time`) and optionally weighted by `query_load_percent` when present

This yields a stable, explainable attribution that ties back to the Snowflake-provided query-attributed bucket.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hourly warehouse metering will not reconcile to billed credits because daily cloud services billing uses an adjustment not present in hourly view. | Confusing UX if not explained; incorrect “billing” charts if built from hourly metering. | Build billing-facing numbers from `METERING_DAILY_HISTORY.CREDITS_BILLED` and label hourly as “metered/operational”. (Docs explicitly warn.) |
| Per-query credit attribution is not directly available in `ACCOUNT_USAGE.QUERY_HISTORY`. | Any query-level cost is a model/estimate rather than ledger truth. | Treat per-query attribution as “estimated”; tie allocations to `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` and document algorithm + limitations. |
| Resource monitors can suspend warehouses but can’t enforce serverless/AI spend. | FinOps app must cover non-warehouse cost controls via budgets/alerts rather than suspension. | Cross-check with Snowflake Budgets docs and implement recommendations accordingly. (Resource Monitor docs explicit.) |
| Timezone handling affects reconciliation across ACCOUNT_USAGE vs ORG_USAGE and even among ACCOUNT_USAGE views. | Mismatched dates/hours. | Standardize on UTC in app SQL sessions (`ALTER SESSION SET TIMEZONE=UTC`) and store timestamps normalized. (Docs recommend UTC for reconciliation.) |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY (hourly warehouse credits; billed reconciliation notes; idle-cost example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. METERING_DAILY_HISTORY (daily billed credits; service types; cloud services adjustment): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. QUERY_HISTORY (query metadata incl. `QUERY_TAG`): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. Resource monitors (warehouse-only enforcement; not serverless/AI; threshold behavior): https://docs.snowflake.com/en/user-guide/resource-monitors
5. DATABASE_STORAGE_USAGE_HISTORY (daily database storage usage; BCR 2025_07 note): https://docs.snowflake.com/en/sql-reference/account-usage/database_storage_usage_history

## Next Steps / Follow-ups

- Pull and cite Snowflake **Budgets** docs (since they’re recommended for serverless + AI services) and map a “controls” matrix: resource monitor vs budget vs alerting.
- Validate whether `ORGANIZATION_USAGE` has equivalent metering views (and any additional columns) and document reconciliation strategy + latency.
- Draft the “estimated query cost allocation” algorithm as an ADR with: definition, math, limitations, and UI labels.
