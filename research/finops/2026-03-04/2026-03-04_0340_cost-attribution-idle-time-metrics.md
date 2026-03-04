# Research: FinOps - 2026-03-04

**Time:** 03:40 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage by warehouse for up to **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (which excludes warehouse idle time). The view has **latency up to 180 minutes** (and up to 6 hours for `CREDITS_USED_CLOUD_SERVICES`). [Snowflake docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. Snowflake’s Well-Architected “Cost Optimization & FinOps” guidance explicitly calls out using `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` + `ACCOUNT_USAGE.QUERY_HISTORY` as primary telemetry for compute/query cost visibility, and recommends granular cost attribution via both **object tags** (for warehouses/databases/etc.) and **query tags** (for shared warehouses) with governance/guardrails via resource monitors and budgets. [Well-Architected guide](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
3. For reconciling ACCOUNT_USAGE vs ORGANIZATION_USAGE, Snowflake docs for `WAREHOUSE_METERING_HISTORY` recommend setting the session timezone to **UTC** before querying to align timestamps. [Snowflake docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
4. A practical warehouse-level “waste” signal can be computed directly from the view as: `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)` over a time window, grouped by warehouse (this is effectively compute credits not attributed to executing queries, i.e., idle/overhead). [Snowflake docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; includes query-attributed compute credits but **not** idle time. Latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Query-level telemetry used for query tags + per-query metrics; referenced by Well-Architected as core compute attribution input. | 
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Suggested by Well-Architected for joining object tags to usage views to allocate costs. (Not extracted in detail in this session; validate columns when implementing.) [Well-Architected guide](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/) |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | ORG_USAGE | Well-Architected cites as org-level metering rollups; use for multi-account views. [Well-Architected guide](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/) |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-time tax + accountability UI:** add a first-class metric “Idle Credits %” per warehouse with drilldowns and alerts (e.g., >30% idle over trailing 7 days) powered solely by `WAREHOUSE_METERING_HISTORY`.
2. **Two-mode cost attribution (explicit + heuristic):**
   - Mode A: “Attributed-only” showback by `QUERY_TAG` for a shared warehouse using query-attributed credits only.
   - Mode B: “All-in” showback that **allocates idle credits** proportionally to tag activity in the same warehouse-hour (a heuristic, but often what finance wants).
3. **FinOps data contract:** standardize a minimal daily fact table (warehouse-hour) with stable columns (`credits_used_*`, `idle_credits`, `utc_hour`, `warehouse_name`) and downstream marts for tag attribution and anomalies.

## Concrete Artifacts

### SQL draft: warehouse idle credits + idle ratio

Directly from `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`.

```sql
-- Warehouse idle credits for the last 30 days
-- Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_utc,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
  warehouse_name,
  SUM(credits_used_compute) AS credits_used_compute,
  SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
  SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_compute_credits,
  IFF(SUM(credits_used_compute) = 0, NULL,
      (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / SUM(credits_used_compute)
  ) AS idle_compute_ratio
FROM wh
GROUP BY 1
ORDER BY idle_compute_credits DESC;
```

### SQL draft: heuristic tag attribution including idle credits (warehouse-hour allocation)

This is a **heuristic** model: allocate (a) query-attributed compute credits and (b) idle compute credits to `QUERY_TAG` based on each tag’s share of execution time within a warehouse-hour. Works best when warehouses are not heavily shared by wildly different workload types.

Inputs:
- Hourly warehouse credits: `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` [docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
- Query telemetry: `ACCOUNT_USAGE.QUERY_HISTORY` [docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_history)

```sql
ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Pull hourly metering with idle credits
WITH wh_hour AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_utc,
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),

-- 2) Bucket queries into warehouse-hours and compute execution seconds by query_tag
q_hour AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_utc,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '__UNSET__') AS query_tag,
    SUM(execution_time/1000.0) AS exec_seconds
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND execution_status = 'SUCCESS'
  GROUP BY 1, 2, 3
),

-- 3) Normalize shares within each warehouse-hour
q_share AS (
  SELECT
    hour_utc,
    warehouse_name,
    query_tag,
    exec_seconds,
    exec_seconds / NULLIF(SUM(exec_seconds) OVER (PARTITION BY hour_utc, warehouse_name), 0) AS exec_share
  FROM q_hour
)

-- 4) Allocate both attributed and idle compute credits
SELECT
  s.hour_utc,
  s.warehouse_name,
  s.query_tag,
  s.exec_seconds,
  s.exec_share,
  w.credits_attributed_compute_queries * s.exec_share AS attributed_compute_credits_alloc,
  w.idle_compute_credits * s.exec_share AS idle_compute_credits_alloc,
  (w.credits_attributed_compute_queries + w.idle_compute_credits) * s.exec_share AS all_in_compute_credits_alloc
FROM q_share s
JOIN wh_hour w
  ON w.hour_utc = s.hour_utc
 AND w.warehouse_name = s.warehouse_name
ORDER BY s.hour_utc DESC, all_in_compute_credits_alloc DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hour-bucketing queries by `DATE_TRUNC('hour', start_time)` is an approximation (queries can span hours). | Mis-allocation for long-running queries near hour boundaries. | Improve by splitting query runtime across hours (more complex), or restrict to queries with `total_elapsed_time` < 1h for this model. |
| Allocating idle credits proportionally to execution time assumes “idle is caused by the same tags that used the warehouse that hour.” | Could unfairly penalize some tags; finance might still prefer it. | Provide both attribution modes (attributed-only vs all-in) and make choice explicit in UI. |
| `CREDITS_USED` may be greater than billed credits; docs note cloud services adjustments and recommend `METERING_DAILY_HISTORY` to determine billed credits. | Dollar conversion mismatch if you directly multiply by contracted rate. | Use `METERING_DAILY_HISTORY` / org currency views for billing reconciliation; keep this model as “usage credits”. [Snowflake docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |

## Links & Citations

1. Snowflake docs — `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (columns, latency, idle example, timezone note): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Well-Architected Framework — Cost Optimization & FinOps (principles; recommends `WAREHOUSE_METERING_HISTORY`, `QUERY_HISTORY`, tagging, monitors/budgets): https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
3. Snowflake docs — `ACCOUNT_USAGE.QUERY_HISTORY` (query telemetry for tags + attribution inputs): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. Snowflake docs — “Optimizing cost” landing page (entry point to cost features/strategies): https://docs.snowflake.com/en/user-guide/cost-optimize

## Next Steps / Follow-ups

- Enhance the attribution SQL to split long-running queries across multiple warehouse-hours (exact allocation).
- Confirm `TAG_REFERENCES` join patterns for warehouse tags vs user tags (and how to handle shared warehouses with user tags vs query tags).
- Add a small ADR: “Showback semantics: attributed vs all-in; treatment of cloud-services credits; rounding + late-arriving data windows.”
