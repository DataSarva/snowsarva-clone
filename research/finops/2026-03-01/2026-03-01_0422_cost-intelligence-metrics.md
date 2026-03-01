# Research: FinOps - 2026-03-01

**Time:** 04:22 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for up to the last **365 days**, including `CREDITS_USED` (compute + cloud services) and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only, excludes idle).  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`. [1]

2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` can be **greater than billed credits** because it does **not** apply the cloud services billing adjustment; Snowflake recommends using `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` to determine **credits actually billed**.  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY` and `METERING_DAILY_HISTORY`. [1][3]

3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily billed credits** and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative rebate/adjustment) and `CREDITS_BILLED` (the billed total).  
   Source: Snowflake docs for `METERING_DAILY_HISTORY`. [3]

4. Cloud services credits are billed only when daily cloud services consumption exceeds **10% of daily warehouse usage** (per Snowflake’s overall cost documentation; also referenced in metering example notes).  
   Source: Snowflake “Understanding overall cost” docs and `METERING_DAILY_HISTORY` example text. [4][3]

5. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` exposes per-query operational signals useful for cost attribution heuristics and optimization triage (e.g., `WAREHOUSE_NAME`, `START_TIME`/`END_TIME`, `TOTAL_ELAPSED_TIME`, `BYTES_SCANNED`, `BYTES_SPILLED_*`, queue times).  
   Source: Snowflake docs for `QUERY_HISTORY`. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse; latency up to ~180 min (and up to 6h for cloud services column per docs). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for query-execution-only credits; excludes idle. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits, including cloud services adjustment/rebate via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`. Latency up to ~180 min per docs. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata and performance signals; can be used to slice by warehouse, time, user, role, query_tag, etc. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle cost leaderboard (warehouse-level)**: materialize “idle credits” per warehouse/day and trend it (warehouse `CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES`). This is a crisp, defensible metric straight from `WAREHOUSE_METERING_HISTORY` docs/examples. [1]

2. **Billed-vs-consumed reconciliation widget**: daily time series that shows (a) `METERING_DAILY_HISTORY.CREDITS_USED_*` vs (b) `CREDITS_BILLED`, including cloud services adjustment, plus “explainers” (10% rule). This keeps the app honest about what is *billed* vs *observed usage*. [3][4]

3. **Query triage for cost spikes (heuristic attribution)**: for a selected warehouse/hour with high `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, rank queries from `QUERY_HISTORY` in that hour by a heuristic weight (elapsed time, spills, bytes scanned) to identify likely drivers. (Explicitly label as heuristic; Snowflake doesn’t directly expose per-query credits in these views.) [1][2]

## Concrete Artifacts

### SQL Draft: Idle credits per warehouse (daily rollup)

> Computes daily warehouse idle credits using Snowflake’s documented relationship between metering credits and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. [1]

```sql
-- Daily idle credits per warehouse
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   - CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes warehouse idle time. [1]
--   - START_TIME is hourly; roll up to date.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time)              AS usage_date,
    warehouse_name,
    SUM(credits_used_compute)                  AS credits_used_compute,
    SUM(credits_attributed_compute_queries)    AS credits_attributed_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2
)
SELECT
  usage_date,
  warehouse_name,
  credits_used_compute,
  credits_attributed_queries,
  GREATEST(credits_used_compute - credits_attributed_queries, 0) AS idle_credits_est
FROM hourly
ORDER BY usage_date DESC, idle_credits_est DESC;
```

### Pseudocode: Hourly query cost attribution (heuristic)

> Goal: given a warehouse/hour, distribute `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` across queries for ranking. This is **not** a billed-cost calculation; it’s a prioritization heuristic built from `QUERY_HISTORY` signals. [1][2]

```text
inputs:
  W = warehouse_name
  H = hour bucket (timestamp)

metering:
  hourly_credits = SUM(WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES)
                  WHERE warehouse_name=W AND start_time=H

queries:
  Q = all QUERY_HISTORY rows where
        warehouse_name=W AND start_time between H and H+1h

weight each query q in Q:
  w(q) = max(1,
             execution_time_ms(q)
             + alpha * bytes_spilled_to_remote_storage(q)
             + beta  * bytes_scanned(q)
             + gamma * queued_overload_time_ms(q))

normalize:
  cost_share(q) = hourly_credits * w(q) / SUM_q w(q)

output:
  rank queries by cost_share(q) desc
  expose fields: query_id, user_name, role_name, query_tag, start/end, bytes_scanned, spills, queue
  label: "heuristic attribution" and link to metering docs
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Per-query credit cost is not directly available in the cited `ACCOUNT_USAGE` views; any query-level “cost” is a heuristic attribution of warehouse-hour query credits. | Users may interpret the number as billed cost; could erode trust if not clearly labeled. | Add UX labeling + doc links; verify if Snowflake provides alternative per-query cost views in `ORGANIZATION_USAGE` / cost management features in later research. [1][2][3] |
| Timezone reconciliation: Snowflake notes UTC session timezone is required to reconcile with `ORGANIZATION_USAGE`. | Misaligned day/hour buckets across sources. | Always set `ALTER SESSION SET TIMEZONE = UTC` (or `UTC` equivalent) in all app-generated queries for usage views. [1][3] |
| Cloud services billing adjustment (10% rule) complicates billed-vs-consumed comparisons. | Confusing dashboards if we compare raw `CREDITS_USED_CLOUD_SERVICES` to billed. | Use `METERING_DAILY_HISTORY.CREDITS_BILLED` as the “billed truth” and show adjustment explicitly. [3][4] |

## Links & Citations

1. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Docs — `QUERY_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. Snowflake Docs — `METERING_DAILY_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
4. Snowflake Docs — Understanding overall cost: https://docs.snowflake.com/en/user-guide/cost-understanding-overall

## Next Steps / Follow-ups

- Confirm what **currency-based** cost views exist (if any) vs credit-based (potentially in `ORGANIZATION_USAGE` or cost management features) and whether they’re available to Native Apps.
- Identify additional `ACCOUNT_USAGE` views needed for “cost drivers” (e.g., storage usage, data transfer) and draft v1 metrics.
- Design a small “Cost Semantics” ADR for the app: definitions for *billed credits*, *consumed credits*, *idle credits*, *cloud services adjustment*.
