# Research: FinOps - 2026-03-01

**Time:** 10:39 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution primitives + idle vs attributed compute)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including total credits used (`CREDITS_USED`) and a field for credits attributed specifically to query execution (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`). It explicitly notes that idle time is **not** included in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, enabling an “idle credits” estimate as `CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. (Latency: up to 3h; cloud services: up to 6h.)
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage that includes a **cloud services adjustment** (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`) and a “billed” rollup (`CREDITS_BILLED`). Snowflake docs note that hourly warehouse metering values may be **greater than billed** credits; billed reconciliation should use `METERING_DAILY_HISTORY`.
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY` provides 5-minute interval “query load” ratios (running / queued / provisioning / blocked), which are useful to distinguish “idle credits due to lack of work” vs “spent while overloaded/queued”.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` contains per-query operational metrics (warehouse, timing, bytes scanned, queued times, etc.) and includes a `QUERY_TAG` column (when set via session parameter). This can be used for **showback** and **workload classification**, but it does not directly provide “billed credits per query” in the snippet extracted here; credits typically require attribution logic or other usage views.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly warehouse credits used; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only) and explicit idle-time guidance; note on billed vs used credits. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | `ACCOUNT_USAGE` | Daily service-type credits; includes cloud services adjustment and `CREDITS_BILLED` for reconciliation. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY` | view | `ACCOUNT_USAGE` | 5-minute interval load ratios: running/queued/provisioning/blocked; latency up to 3h. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | `ACCOUNT_USAGE` | Per-query dimensions + `QUERY_TAG`; operational metrics for triage (queued times, bytes scanned, spills, etc.). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle credits KPI per warehouse (daily + trailing 7/30):** Implement a canonical “idle credits” metric using `WAREHOUSE_METERING_HISTORY` (`idle = credits_used_compute - credits_attributed_compute_queries`) and surface it as a leaderboard + trend.
2. **Overload vs idle diagnosis:** Join daily/hourly idle with `WAREHOUSE_LOAD_HISTORY` to differentiate (a) idling (not enough work) vs (b) queuing/overload (warehouse too small / concurrency too high).
3. **Query tag showback (approx):** If customers use `QUERY_TAG` consistently, build an initial “cost by query_tag” by allocating hourly warehouse compute credits proportionally to query execution time in that hour. (Mark as approximation; see risks.)

## Concrete Artifacts

### SQL Draft: Warehouse hourly attribution + idle credits

This view is a stable primitive for the app’s warehouse-level cost metrics.

```sql
-- FINOPS primitive: warehouse-hour compute used vs attributed vs idle
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   * CREDITS_USED may exceed billed credits; billed reconciliation should use METERING_DAILY_HISTORY.
--   * View latency: up to ~3h (cloud services up to ~6h).

create or replace view FINOPS.FACT_WAREHOUSE_HOURLY_CREDITS as
select
  start_time,
  end_time,
  warehouse_id,
  warehouse_name,
  credits_used_compute,
  credits_attributed_compute_queries,
  greatest(credits_used_compute - credits_attributed_compute_queries, 0) as credits_idle_compute_est,
  credits_used_cloud_services,
  credits_used
from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY;
```

### SQL Draft: Query-tag allocation (approximation) from hourly warehouse credits

Goal: approximate showback by `QUERY_TAG` by allocating a warehouse-hour’s **compute** credits proportionally to query execution time in that same hour.

```sql
-- Approximate showback: allocate warehouse-hour credits to query_tag by execution_time share
-- WARNING: approximation; see Risks/Assumptions.

with q as (
  select
    warehouse_name,
    date_trunc('hour', start_time) as hour_start,
    coalesce(nullif(query_tag, ''), '<UNSET>') as query_tag,
    sum(execution_time) as exec_ms
  from SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  where start_time >= dateadd('day', -30, current_timestamp())
    and warehouse_name is not null
    and execution_status = 'SUCCESS'
  group by 1,2,3
),
q_tot as (
  select warehouse_name, hour_start, sum(exec_ms) as total_exec_ms
  from q
  group by 1,2
),
w as (
  select
    warehouse_name,
    start_time as hour_start,
    credits_used_compute
  from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  where start_time >= dateadd('day', -30, current_date())
)
select
  q.warehouse_name,
  q.hour_start,
  q.query_tag,
  q.exec_ms,
  q_tot.total_exec_ms,
  w.credits_used_compute,
  iff(q_tot.total_exec_ms = 0, 0,
      w.credits_used_compute * (q.exec_ms / q_tot.total_exec_ms)) as approx_credits_used_compute
from q
join q_tot
  on q.warehouse_name = q_tot.warehouse_name
 and q.hour_start = q_tot.hour_start
join w
  on q.warehouse_name = w.warehouse_name
 and q.hour_start = w.hour_start;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| **Used vs billed mismatch:** hourly `CREDITS_USED` may exceed billed credits due to cloud services adjustment and billing rules. | “Cost” dashboards can disagree with invoices. | Provide both “consumed” and “billed” layers; reconcile daily with `METERING_DAILY_HISTORY.CREDITS_BILLED`. |
| Latency up to ~3h (and cloud services up to 6h) for `WAREHOUSE_METERING_HISTORY`. | Near-real-time alerts may look “late”. | Document freshness; optionally compute “as-of” watermark. |
| Query-tag allocation is **approximate** (execution time not a perfect proxy for share of credits, and idle time exists). | Showback accuracy may be disputed. | Label as “estimate”; prefer dedicated attribution views if available in the account; benchmark against known workloads. |
| Timezone reconciliation: docs advise setting timezone to UTC to reconcile ACCOUNT_USAGE with ORG_USAGE. | Off-by-one-day/hour reporting errors. | Standardize app queries to `ALTER SESSION SET TIMEZONE = UTC;` or use explicit conversion in views. |

## Links & Citations

1. `WAREHOUSE_METERING_HISTORY` view (hourly credits, attributed vs idle guidance, latency notes): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. `METERING_DAILY_HISTORY` view (daily billed credits + cloud services adjustment): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Compute cost billing rules (per-second billing + 60s minimum, cloud services discussion, etc.): https://docs.snowflake.com/en/user-guide/cost-understanding-compute
4. `WAREHOUSE_LOAD_HISTORY` view (5-minute load ratios, queuing/provisioning/blocked): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_load_history
5. `QUERY_HISTORY` view (dimensions incl. `QUERY_TAG`, bytes scanned, queued times, etc.): https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Add an app-level “Cost Metrics Layer” contract:
  - consumed credits: `WAREHOUSE_METERING_HISTORY` (hourly)
  - billed credits: `METERING_DAILY_HISTORY` (daily)
  - derived: idle compute credits + idle ratio + queued/blocked ratios
- Decide whether to ship query-tag showback as an **MVP estimate** or gate it behind “advanced attribution” and customer opt-in.
- Track down/confirm best-practice official sources for org-wide currency views (`ORG_USAGE`) once we have search tooling (Brave/Parallel) configured.
