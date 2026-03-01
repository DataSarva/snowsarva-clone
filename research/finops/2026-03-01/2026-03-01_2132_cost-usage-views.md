# Research: FinOps - 2026-03-01

**Time:** 21:32 UTC  
**Topic:** Snowflake FinOps Cost Optimization (compute / warehouse + query signals)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** warehouse credit usage for the last **365 days**, with up to **~3 hours** latency (and up to **~6 hours** for `CREDITS_USED_CLOUD_SERVICES`). It includes columns to separate compute vs cloud services credits and a column (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`) that attributes compute credits to queries but **excludes warehouse idle time**. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` provides **query-level** operational signals (e.g., `TOTAL_ELAPSED_TIME`, `BYTES_SCANNED`, `WAREHOUSE_NAME`, queuing times, spill bytes) for up to **365 days**, but with up to **~45 minutes** latency; it also includes `QUERY_HASH` and `QUERY_PARAMETERIZED_HASH` for grouping structurally-similar queries. (https://docs.snowflake.com/en/sql-reference/account-usage/query_history)
3. A **resource monitor** can send notifications and/or suspend **user-managed virtual warehouses** when credit thresholds are hit; it **does not** track serverless features / AI services spend (Snowflake docs recommend using a **budget** for those). (https://docs.snowflake.com/en/user-guide/resource-monitors)
4. Resource monitor credit limits are computed using cloud services credits **without** considering the daily **10% cloud services adjustment**; i.e., a monitor can trigger using credit consumption that may not ultimately be billed. (https://docs.snowflake.com/en/user-guide/resource-monitors)
5. Snowflake’s Well-Architected “Cost Optimization” guidance frames FinOps as: establish principles, improve visibility, implement controls/guardrails (budgets/resource monitors), and continuously optimize—explicitly calling out unit economics (e.g., credits per 1K queries / credits per TB scanned) and anomaly investigation as core practices. (https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits used by warehouse; 1y retention; latency up to 3h (6h for cloud services column). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed compute credits) which excludes idle. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level metrics & hashes; 1y retention; latency up to 45m. Useful for cost drivers (scan bytes, spill, queuing) but not a direct per-query credit bill. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned by metering views as source for determining **credits actually billed** (vs raw cloud services consumption). Not deep-read in this session; validate before shipping. (Referenced from `WAREHOUSE_METERING_HISTORY` / `QUERY_HISTORY` docs.) |
| `RESOURCE MONITOR` | Object | N/A (DDL object) | Guardrail/control primitive for warehouses only. Requires `ACCOUNTADMIN` to create; can delegate MONITOR/MODIFY on specific monitors. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle-time cost surfacing (warehouse efficiency scorecard):** compute “idle credits” per warehouse using `WAREHOUSE_METERING_HISTORY` (`credits_used_compute - credits_attributed_compute_queries`). Ship as a simple dashboard widget + API endpoint.
2. **Cost-driver query finder (performance → cost heuristics):** rank query patterns (by `QUERY_PARAMETERIZED_HASH`) by **bytes scanned**, **spill**, and **queued time** to identify systematic inefficiencies (bad clustering/pruning, concurrency pressure, etc.).
3. **Guardrail audit pack:** detect which warehouses lack cost guardrails (no resource monitor; auto-suspend too high/disabled; missing query tags). (Resource monitor capabilities/constraints are clear + enforceable.)

## Concrete Artifacts

### SQL Draft: Warehouse idle credits over trailing N days

Directly derived from Snowflake’s example and expanded with guardrails.

```sql
-- Idle compute credits per warehouse over last N days.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--  - credits_attributed_compute_queries excludes idle time
--  - credits_used includes compute + cloud services; below we focus on compute

SET N_DAYS = 14;

SELECT
  warehouse_name,
  SUM(credits_used_compute)                            AS compute_credits_total,
  SUM(credits_attributed_compute_queries)              AS compute_credits_attributed_to_queries,
  SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS compute_credits_idle,
  IFF(SUM(credits_used_compute) = 0, NULL,
      (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / SUM(credits_used_compute)
  ) AS pct_compute_idle
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -$N_DAYS, CURRENT_DATE())
  AND end_time <  CURRENT_DATE()
GROUP BY 1
ORDER BY compute_credits_idle DESC;
```

Citations:
- Idle time formula/example is explicitly shown in `WAREHOUSE_METERING_HISTORY` docs. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)

### SQL Draft: Top “cost driver” query patterns (grouped)

This is not “credits per query” (Snowflake bills by warehouse uptime), but it’s a *high-signal heuristic* for where to optimize.

```sql
-- Top query patterns by scanned bytes and elapsed time.
-- Group by QUERY_PARAMETERIZED_HASH to find repeat offenders.

SET N_DAYS = 7;

WITH q AS (
  SELECT
    query_parameterized_hash,
    warehouse_name,
    query_type,
    COUNT(*)                                   AS executions,
    SUM(bytes_scanned)                          AS bytes_scanned_total,
    SUM(total_elapsed_time) / 1000.0            AS elapsed_s_total,
    SUM(bytes_spilled_to_remote_storage)        AS spill_remote_bytes_total,
    SUM(queued_overload_time) / 1000.0          AS queued_overload_s_total
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -$N_DAYS, CURRENT_TIMESTAMP())
    AND execution_status = 'success'
    AND warehouse_name IS NOT NULL
  GROUP BY 1,2,3
)
SELECT *
FROM q
QUALIFY ROW_NUMBER() OVER (ORDER BY bytes_scanned_total DESC) <= 50
ORDER BY bytes_scanned_total DESC;
```

Citations:
- `QUERY_HISTORY` columns for `BYTES_SCANNED`, `TOTAL_ELAPSED_TIME`, spill/queue times, and hashes are documented. (https://docs.snowflake.com/en/sql-reference/account-usage/query_history)

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `CREDITS_USED` in metering views may differ from “credits billed” due to cloud services adjustments; docs point to `METERING_DAILY_HISTORY` for reconciliation. | Incorrect dollar mapping if we equate these to invoiced credits. | Add a reconciliation module using `METERING_DAILY_HISTORY` and document any discrepancies. (See metering docs.) |
| Per-query “cost” is inherently indirect because billing is warehouse-uptime based; query-level signals should be presented as *drivers*, not invoices. | Users may expect exact per-query dollars. | UI/UX: label as “cost drivers” + provide drill-down to warehouse-hour metering. |
| Resource monitors only apply to **warehouses**, not serverless / AI services (budgets required). | Coverage gaps if our app claims “global spend control”. | Explicit coverage matrix in product + implement budgets lane separately. (https://docs.snowflake.com/en/user-guide/resource-monitors) |
| Account Usage views have latency (45m to 6h depending on column/view). | Near-real-time dashboards can look stale. | Add freshness indicators + optional INFORMATION_SCHEMA table functions for recent windows where applicable (7d retention). |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY (Account Usage view) — columns, latency, idle-cost example, UTC timezone note: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. QUERY_HISTORY (Account Usage view) — 365d query-level metrics + hashes + latency note: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. Working with resource monitors — triggers/actions, warehouse-only scope, cloud services adjustment note: https://docs.snowflake.com/en/user-guide/resource-monitors
4. Snowflake Well-Architected Framework: Cost Optimization & FinOps — principles + recommended practices: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Deep read + extract `METERING_DAILY_HISTORY` (and related “usage in currency” views if applicable) to formalize a **billing-reconciled** cost model (credits billed vs consumed).
- Decide on a first-class internal semantic model for FinOps:
  - `warehouse_hour` facts from `WAREHOUSE_METERING_HISTORY`
  - `query` facts from `QUERY_HISTORY`
  - derived metrics: idle %, scan-per-result, spill rate, overload queue time
- Define UX language to avoid implying precise “per-query $” where it isn’t defensible.
