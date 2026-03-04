# Research: FinOps - 2026-03-04

**Time:** 03:42 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Cost Intelligence building blocks for Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage for warehouses for up to the last **365 days**, including both compute and cloud services, and includes a column that attributes compute credits to queries (excluding idle). (Snowflake docs) 
2. You can estimate **warehouse idle cost** by subtracting `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` from `CREDITS_USED_COMPUTE` aggregated over a period. (Snowflake docs example query)
3. Account Usage views have **latency** (commonly up to hours), and reconciling account-level vs organization-level metering views requires setting the session timezone to **UTC** first. (Snowflake docs)
4. Snowflake’s own cost/performance optimization guidance for admins repeatedly centers on: (a) enforcing warehouse controls (auto-suspend/auto-resume/statement timeouts/resource monitors), (b) using Account Usage to find savings opportunities, and (c) leveraging managed optimization features (automatic clustering, materialized views, query acceleration, search optimization) with cost awareness. (Snowflake developer guide)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits; includes `CREDITS_USED_{COMPUTE,CLOUD_SERVICES}` + `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-only compute, no idle). Latency up to hours; cloud services latency can be longer. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query metadata needed for attribution (warehouse, user/role, query_tag, timings). Mentioned in Snowflake guide as a primary source for optimization investigation. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Useful to identify unused objects / usage patterns; included in Snowflake guide’s “Account Usage Queries.” |
| `SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS` | View | `ACCOUNT_USAGE` | Used in Snowflake guide to detect high-churn / short-lived tables and storage cost opportunities. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle-cost spotlight** (warehouse “idle tax”): daily/hourly idle credits per warehouse with trend + “top offenders” list, backed by `WAREHOUSE_METERING_HISTORY` idle formula.
2. **Warehouse controls linter**: detect warehouses without recommended guardrails (auto-suspend, statement timeouts, resource monitor), then generate safe `ALTER WAREHOUSE` / `CREATE RESOURCE MONITOR` snippets aligned with Snowflake guidance.
3. **Cost optimization playbooks surfaced from telemetry**: for a warehouse with high idle or high cloud services share, recommend targeted actions and link to the exact Snowflake doc section.

## Concrete Artifacts

### SQL Draft: Warehouse idle credits + utilization efficiency (daily)

Purpose: generate a compact daily table your Native App can materialize and chart.

```sql
-- Warehouse daily rollup with idle credits estimate.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Note: START_TIME/END_TIME are in local timezone; set UTC if reconciling with ORG_USAGE.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('day', start_time)                                  AS usage_day,
    warehouse_id,
    warehouse_name,
    SUM(credits_used)                                              AS credits_used_total,
    SUM(credits_used_compute)                                      AS credits_used_compute,
    SUM(credits_used_cloud_services)                               AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries)                        AS credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
    AND end_time   <  CURRENT_DATE()
  GROUP BY 1,2,3
)
SELECT
  usage_day,
  warehouse_id,
  warehouse_name,
  credits_used_total,
  credits_used_compute,
  credits_used_cloud_services,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries)      AS credits_idle_compute,
  IFF(credits_used_compute = 0,
      NULL,
      (credits_used_compute - credits_attributed_compute_queries) / credits_used_compute
  )                                                                AS idle_ratio_compute
FROM hourly
ORDER BY usage_day DESC, credits_used_total DESC;
```

### ADR Sketch: “Two-lane” cost attribution in the app

**Problem:** Users want “cost per query_tag / team,” but warehouse idle time is not naturally attributable.

**Decision:** Ship two parallel metrics:
- **Attributed-only cost**: show what Snowflake attributes to query execution (excluding idle) to avoid misleading allocations.
- **All-in cost (includes idle)**: optionally allocate idle proportionally (e.g., by share of attributed credits) with clear labeling.

**Rationale:** Snowflake explicitly exposes both `CREDITS_USED_COMPUTE` (includes idle) and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-only compute), enabling transparent presentation and user choice. (Snowflake docs)

**Consequences:**
- UI must clearly label which lane is being viewed.
- Reconciliation and anomaly detection become easier (you can explain deltas as idle).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Account Usage latency (hours) will delay “near-real-time” dashboards. | Users might expect immediate cost signals. | Design UX with freshness badges + backfill job; documented latency in Snowflake Account Usage + WAREHOUSE_METERING_HISTORY docs. |
| `START_TIME`/`END_TIME` timestamps are local-time; org reconciliation requires UTC session timezone. | Misalignment when combining `ACCOUNT_USAGE` with `ORGANIZATION_USAGE`. | Enforce `ALTER SESSION SET TIMEZONE='UTC'` in all cost pipelines. |
| CREDITS_USED may exceed billed credits if cloud services adjustment applies; “billed” requires other metering views (e.g., daily). | Potential mismatch vs invoices. | Add a follow-up research lane to identify “billed credits” canonical source for invoice reconciliation. |

## Links & Citations

1. Snowflake docs: Optimizing cost — https://docs.snowflake.com/en/user-guide/cost-optimize
2. Snowflake docs: `WAREHOUSE_METERING_HISTORY` (Account Usage view) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake developer guide: Getting Started with Cost and Performance Optimization — https://www.snowflake.com/en/developers/guides/getting-started-cost-performance-optimization/
4. Snowflake docs: Account Usage overview + timezone reconciling guidance — https://docs.snowflake.com/en/sql-reference/account-usage

## Next Steps / Follow-ups

- Pull + cite canonical “billed credits” source (likely `METERING_DAILY_HISTORY`) and document a reconciliation recipe vs `WAREHOUSE_METERING_HISTORY`.
- Extend the artifact into a **query_tag cost allocation** view using `QUERY_HISTORY` joined to metering, emitting both attributed-only and all-in lanes.
- Define minimum privileges / database roles required for a Native App to read required `SNOWFLAKE.ACCOUNT_USAGE` views (package as an install checklist).
