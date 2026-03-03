# Research: FinOps - 2026-03-03

**Time:** 1633 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s Well-Architected “Cost Optimization” guidance explicitly recommends using **object tags** (with inheritance/propagation) and **query tags** to enable granular cost attribution, and points to joining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with usage views (e.g., `WAREHOUSE_METERING_HISTORY`, `TABLE_STORAGE_METRICS`) for allocation.  
   Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

2. `SNOWFLAKE.ACCOUNT_USAGE` views have **latency** (varies by view) and **1-year retention**; Snowflake advises avoiding `SELECT *` because these views are subject to change. Reconciling account vs org cost views requires setting session timezone to **UTC**.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage

3. Snowflake provides an official tutorial showing a simple (but lossy) approach to “credits per query” by joining `ACCOUNT_USAGE.QUERY_HISTORY` to `ACCOUNT_USAGE.METERING_HISTORY` using start/end time containment. This yields a `CREDITS_USED` value at the metering grain joined to queries.  
   Source: https://www.snowflake.com/en/developers/guides/query-cost-monitoring/

4. `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` is a **table function** returning hourly credit usage for the last **6 months**; Snowflake docs note that for long time ranges / multiple warehouses you should use the **ACCOUNT_USAGE** view for a more complete dataset.  
   Source: https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

5. A third-party deep dive notes limitations / behaviors of `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (e.g., only available from 2024-07-01 onward, excluding very short queries, and not including idle time), and suggests validating it against metering history; it also shows a concrete approach to allocate warehouse metering credits across query runtime and idle time using `WAREHOUSE_EVENTS_HISTORY` and a time-weighted method.  
   Source: https://blog.greybeam.ai/snowflake-cost-per-query/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | 45 min latency; 1 yr retention; contains `QUERY_TAG` (via query tag feature). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly-ish metering grain in examples; used in Snowflake Streamlit cost monitoring quickstart. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; canonical for warehouse credit reconciliation in many analyses. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | ACCOUNT_USAGE | Can be used to infer suspend / resume events; third-party sources note historical reliability concerns but improvements. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | 8 hour latency per Account Usage docs; third-party notes additional constraints (availability window, excludes very short queries, idle time excluded). Validate in target accounts. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Used to map object tags to warehouses/users/etc for showback/chargeback; referenced in Well-Architected Cost Optimization guide. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | INFO_SCHEMA | Returns last 6 months; for completeness across many warehouses/time ranges prefer ACCOUNT_USAGE. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution “Confidence Grades”**: Implement query cost as a multi-source metric with a confidence label per row:
   - Grade A: `QUERY_ATTRIBUTION_HISTORY` present + reconciles within tolerance to metered warehouse credits for same hour.
   - Grade B: time-weighted allocation using `WAREHOUSE_METERING_HISTORY` + query runtime + inferred idle from `WAREHOUSE_EVENTS_HISTORY`.
   - Grade C: simple containment join to `METERING_HISTORY` (quickstart method).
   This lets the app ship value even when certain views/features aren’t enabled.

2. **Tag hygiene scorecard**: Use `TAG_REFERENCES` + `QUERY_HISTORY.QUERY_TAG` to report “% un-attributed credits” by warehouse/user/schema, and create an “Untagged / Unquery-tagged spend” KPI.

3. **Showback-ready mart**: Materialize a daily mart that outputs costs by (warehouse_tag_cost_center, query_tag_workload, user_tag_team) with a rule-based idle allocation policy (e.g., idle attributed to warehouse owner or split by last N minutes of query activity).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Query + Idle time weighted credit attribution (hourly metering)

This is a draft adapted from the Greybeam approach, structured as an app-owned view / dynamic table. It intentionally separates:
- “query runtime events” and “idle events”
- allocation to `WAREHOUSE_METERING_HISTORY` hourly credits

```sql
-- PURPOSE
-- Allocate metered warehouse compute credits across query runtime + idle time.
-- Produces a per-(query_id OR idle_event_id)-per-hour allocation that sums to metered credits.
--
-- NOTES
-- - Requires ACCOUNT_USAGE access to QUERY_HISTORY / WAREHOUSE_METERING_HISTORY / WAREHOUSE_EVENTS_HISTORY.
-- - Uses a time-weighted allocation within each (warehouse_id, hour).
-- - Assumes credits are proportional to time within the hour (approximation).
--
-- Sources / inspiration:
-- - Greybeam cost attribution write-up (time-weighted across query + idle)
--   https://blog.greybeam.ai/snowflake-cost-per-query/
-- - Account Usage view behaviors + UTC reconciliation note
--   https://docs.snowflake.com/en/sql-reference/account-usage

ALTER SESSION SET TIMEZONE = 'UTC';

SET start_date = DATEADD('DAY', -15, CURRENT_DATE());

WITH warehouse_hours AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time::timestamp_ntz AS meter_hour,
    credits_used_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= $start_date
),

warehouse_suspend_events AS (
  -- Use suspend events as end-markers for idle windows
  SELECT
    warehouse_id,
    timestamp::timestamp_ntz AS event_ts
  FROM snowflake.account_usage.warehouse_events_history
  WHERE event_name = 'SUSPEND_WAREHOUSE'
    AND timestamp >= $start_date
),

queries AS (
  SELECT
    qh.query_id,
    qh.warehouse_id,
    qh.warehouse_name,
    qh.user_name,
    qh.role_name,
    qh.query_tag,
    qh.start_time::timestamp_ntz AS start_time,
    qh.end_time::timestamp_ntz   AS end_time,

    -- approximate execution start time (exclude queue/compile overhead)
    TIMEADD(
      'millisecond',
      COALESCE(qh.queued_overload_time,0)
      + COALESCE(qh.compilation_time,0)
      + COALESCE(qh.queued_provisioning_time,0)
      + COALESCE(qh.queued_repair_time,0)
      + COALESCE(qh.list_external_files_time,0),
      qh.start_time
    )::timestamp_ntz AS execution_start_time
  FROM snowflake.account_usage.query_history qh
  WHERE qh.execution_status = 'SUCCESS'
    AND qh.warehouse_id IS NOT NULL
    AND qh.start_time >= $start_date
),

queries_with_suspend AS (
  -- Find the next suspend event after each query end.
  -- NOTE: Snowflake supports ASOF JOIN; if not available in account/edition, replace with correlated subquery.
  SELECT
    q.*,
    se.event_ts AS suspended_at,
    LEAD(execution_start_time) OVER (PARTITION BY warehouse_id ORDER BY execution_start_time) AS next_query_at,
    MAX(end_time) OVER (
      PARTITION BY warehouse_id, se.event_ts
      ORDER BY execution_start_time
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS end_time_running
  FROM queries q
  ASOF JOIN warehouse_suspend_events se
    MATCH_CONDITION (q.end_time <= se.event_ts)
    ON q.warehouse_id = se.warehouse_id
),

query_and_idle_windows AS (
  SELECT
    query_id,
    warehouse_id,
    warehouse_name,
    user_name,
    role_name,
    query_tag,

    -- query window
    execution_start_time AS query_start_at,
    end_time             AS query_end_at,

    -- idle window start depends on whether other queries still running
    (CASE
      WHEN next_query_at IS NULL THEN end_time
      WHEN next_query_at > LEAST(suspended_at, end_time_running) THEN end_time_running
      WHEN next_query_at > end_time_running THEN end_time_running
      WHEN next_query_at < end_time_running THEN NULL
      ELSE end_time
    END)::timestamp_ntz AS idle_start_at,

    IFF(
      idle_start_at IS NOT NULL,
      LEAST(COALESCE(next_query_at, '3000-01-01'::timestamp_ntz), suspended_at),
      NULL
    )::timestamp_ntz AS idle_end_at
  FROM queries_with_suspend
),

numgen AS (
  SELECT 0 AS n
  UNION ALL
  SELECT ROW_NUMBER() OVER (ORDER BY NULL)
  FROM TABLE(GENERATOR(ROWCOUNT => 48)) -- safety bound
),

hourly_events AS (
  -- Expand query windows across hour boundaries
  SELECT
    q.query_id AS event_id,
    q.query_id AS original_query_id,
    q.warehouse_id,
    q.warehouse_name,
    q.user_name,
    q.role_name,
    q.query_tag,
    'query' AS event_type,

    DATEADD('HOUR', numgen.n, DATE_TRUNC('HOUR', q.query_start_at)) AS meter_hour,
    GREATEST(DATEADD('HOUR', numgen.n, DATE_TRUNC('HOUR', q.query_start_at)), q.query_start_at) AS meter_start_at,
    LEAST   (DATEADD('HOUR', numgen.n+1, DATE_TRUNC('HOUR', q.query_start_at)), q.query_end_at)   AS meter_end_at,

    DATEDIFF('MILLISECOND', meter_start_at, meter_end_at) / 1000.0 AS meter_time_secs
  FROM query_and_idle_windows q
  JOIN numgen
    ON DATEDIFF('HOUR', q.query_start_at, q.query_end_at) >= numgen.n

  UNION ALL

  -- Expand idle windows across hour boundaries
  SELECT
    'idle_' || q.query_id AS event_id,
    q.query_id            AS original_query_id,
    q.warehouse_id,
    q.warehouse_name,
    q.user_name,
    q.role_name,
    q.query_tag,
    'idle' AS event_type,

    DATEADD('HOUR', numgen.n, DATE_TRUNC('HOUR', q.idle_start_at)) AS meter_hour,
    GREATEST(DATEADD('HOUR', numgen.n, DATE_TRUNC('HOUR', q.idle_start_at)), q.idle_start_at) AS meter_start_at,
    LEAST   (DATEADD('HOUR', numgen.n+1, DATE_TRUNC('HOUR', q.idle_start_at)), q.idle_end_at)   AS meter_end_at,

    DATEDIFF('MILLISECOND', meter_start_at, meter_end_at) / 1000.0 AS meter_time_secs
  FROM query_and_idle_windows q
  JOIN numgen
    ON q.idle_start_at IS NOT NULL
   AND q.idle_end_at   IS NOT NULL
   AND DATEDIFF('HOUR', q.idle_start_at, q.idle_end_at) >= numgen.n
),

metered_allocation AS (
  SELECT
    e.*,
    wh.credits_used_compute,
    SUM(e.meter_time_secs) OVER (PARTITION BY e.warehouse_id, e.meter_hour) AS total_meter_time_secs,
    (e.meter_time_secs / NULLIF(total_meter_time_secs,0)) * wh.credits_used_compute AS credits_allocated_compute
  FROM hourly_events e
  JOIN warehouse_hours wh
    ON e.warehouse_id = wh.warehouse_id
   AND e.meter_hour   = wh.meter_hour
)

SELECT *
FROM metered_allocation;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` coverage/behavior differs by account/edition and may exclude short queries and idle time (per third-party report). | If we depend on it, we may under/over attribute costs or miss workloads entirely. | Build reconciliation checks vs `WAREHOUSE_METERING_HISTORY` hourly totals; flag gaps. See https://blog.greybeam.ai/snowflake-cost-per-query/ |
| Time-weighted allocation assumes credits proportional to time within hour. | Attribution may be directionally correct but not exact, especially with multi-cluster warehouses or changing warehouse sizes. | Compare allocated totals to metered totals (must match by construction) and sanity-check distribution on known workloads. |
| `WAREHOUSE_EVENTS_HISTORY` reliability / semantics (suspend vs “fully released”) may vary. | Idle windows might be truncated/extended incorrectly. | Compare “idle minutes per hour” to warehouse utilization metrics where available; verify suspend timestamps on a small set of warehouses. |
| Account Usage latency (45 min–8+ hours) may break “near-real-time” dashboards. | Users may see partial data and think it’s wrong. | Add freshness indicators; default time windows with sufficient backfill (e.g., last complete 24h). Source: https://docs.snowflake.com/en/sql-reference/account-usage |

## Links & Citations

1. Snowflake Well-Architected Framework – Cost Optimization & FinOps (tagging strategy, cost visibility/control/optimize guidance):
   https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
2. Snowflake Docs – Account Usage (latency/retention, database roles, UTC reconciliation note):
   https://docs.snowflake.com/en/sql-reference/account-usage
3. Snowflake Developer Guide – Build a Query Cost Monitoring Tool (Streamlit; join query_history to metering_history example):
   https://www.snowflake.com/en/developers/guides/query-cost-monitoring/
4. Snowflake Docs – WAREHOUSE_METERING_HISTORY table function (6 month window; prefer ACCOUNT_USAGE view for completeness):
   https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
5. Greybeam deep dive – Query cost + idle time attribution and `QUERY_ATTRIBUTION_HISTORY` caveats:
   https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Pull Snowflake docs for `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` and `ACCOUNT_USAGE.WAREHOUSE_UTILIZATION` (if public) to confirm constraints and enablement requirements; update this note with authoritative details.
- Define a product stance for idle-time allocation (idle credits to warehouse owner vs last-query tag vs proportional to runtime over trailing window).
- Add a “Tagging enforcement” recommendation as a first-class setup step for the Native App: required warehouse tags + mandatory query_tag conventions (per workload/app/user).
