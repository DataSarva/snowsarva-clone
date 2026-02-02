# FinOps Research Note — Warehouse hourly cost attribution + idle-time detection (ACCOUNT_USAGE)

- **When (UTC):** 2026-02-02 09:20
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs *explainable*, near-real-time-ish (3–6h lag) compute cost signals to power showback/chargeback, anomaly detection, and actionable recommendations (right-size, scheduling, query optimization). Warehouse-level hourly metering plus query history enables baseline attribution and explicit *idle cost* detection.

## Accurate takeaways
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credits used for up to **365 days**, including:
  - `CREDITS_USED` (= compute + cloud services), and
  - `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributable to query execution only; **excludes idle time**).
- `CREDITS_USED` in `WAREHOUSE_METERING_HISTORY` **may exceed billed credits** because it does **not** account for the cloud services adjustment; Snowflake docs recommend using `METERING_DAILY_HISTORY` to determine credits actually billed.
- Latency is documented as up to **180 minutes** for most columns in `WAREHOUSE_METERING_HISTORY`; `CREDITS_USED_CLOUD_SERVICES` can lag up to **6 hours**.
- A simple, explainable idle-time signal exists at warehouse-hour granularity:
  - `idle_credits ~= credits_used_compute - credits_attributed_compute_queries` (as in Snowflake’s own example).

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly warehouse metering; 3–6h lag)
- `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` (daily billed credits; used for reconciliation / billing truth)
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (query-level metadata; join key is typically `WAREHOUSE_NAME` + time bucket; no direct per-query credit in this view)

Open question (for later): for **per-query credit** attribution, validate availability/semantics of query attribution views/functions (e.g., `QUERY_ATTRIBUTION_HISTORY`) vs using warehouse-hour apportionment.

## MVP features unlocked (PR-sized)
1) **Idle-time cost widget (per warehouse)**
   - Daily + last-24h idle credits, idle % trend, and top offenders.
2) **Warehouse showback v1** (hourly → daily rollup)
   - Show credits by warehouse and optionally allocate idle cost to teams/users (see heuristics).
3) **Reconciliation report**
   - Compare sum of hourly metering to daily billed credits (explain delta; highlight cloud services adjustment effects).

## Heuristics / detection logic (v1)
- **Idle credits per warehouse-hour**
  - `idle_credits = greatest(0, credits_used_compute - credits_attributed_compute_queries)`
- **Idle ratio per hour**
  - `idle_ratio = idle_credits / nullif(credits_used_compute, 0)`
- **Anomaly (simple, robust)**
  - warehouse-hour idle_ratio > p95 over trailing 14 days AND idle_credits > threshold

## Concrete artifact — SQL draft (hourly idle cost + optional allocation)

### A) Hourly idle cost per warehouse
```sql
-- Idle credits per warehouse-hour (ACCOUNT_USAGE)
-- Notes:
-- - WAREHOUSE_METERING_HISTORY timestamps are local TZ; set UTC if reconciling vs ORG_USAGE.
-- - Data lags up to 3–6h.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    start_time,
    end_time,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries,
    GREATEST(0, credits_used_compute - credits_attributed_compute_queries) AS idle_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
)
SELECT
  DATE_TRUNC('hour', start_time) AS hour_utc,
  warehouse_name,
  SUM(credits_used_compute) AS credits_compute,
  SUM(credits_attributed_compute_queries) AS credits_query_exec,
  SUM(idle_credits) AS credits_idle,
  DIV0(SUM(idle_credits), NULLIF(SUM(credits_used_compute), 0)) AS idle_ratio
FROM wh
GROUP BY 1, 2
ORDER BY 1 DESC, 5 DESC;
```

### B) Optional: Allocate idle credits proportionally to teams/users by query count (warehouse-hour)
This is a **stopgap** when per-query credits are not available (or are too laggy). It allocates each warehouse-hour’s `idle_credits` proportionally to each “cost center”’s share of query executions.

```sql
ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_utc,
    warehouse_name,
    SUM(GREATEST(0, credits_used_compute - credits_attributed_compute_queries)) AS idle_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
qh AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_utc,
    warehouse_name,
    -- Replace this with your real cost center mapping:
    COALESCE(query_tag, 'UNSET') AS cost_center,
    COUNT(*) AS query_count
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2, 3
),
qh_tot AS (
  SELECT hour_utc, warehouse_name, SUM(query_count) AS total_query_count
  FROM qh
  GROUP BY 1, 2
)
SELECT
  qh.hour_utc,
  qh.warehouse_name,
  qh.cost_center,
  wh.idle_credits,
  qh.query_count,
  qh_tot.total_query_count,
  wh.idle_credits * (qh.query_count / NULLIF(qh_tot.total_query_count, 0)) AS allocated_idle_credits
FROM qh
JOIN qh_tot
  ON qh_tot.hour_utc = qh.hour_utc
 AND qh_tot.warehouse_name = qh.warehouse_name
JOIN wh
  ON wh.hour_utc = qh.hour_utc
 AND wh.warehouse_name = qh.warehouse_name;
```

## Security/RBAC notes
- `SNOWFLAKE.ACCOUNT_USAGE` is typically readable by `ACCOUNTADMIN` and roles with imported privileges; the app will likely need a **privileged service role** and/or customer-granted privileges for required views.
- Be explicit about data minimization: `QUERY_HISTORY` can include query text; prefer selecting only needed columns.

## Risks / assumptions
- **Attribution fidelity:** warehouse-hour idle allocation by query count is crude; better mappings include query execution time, bytes scanned, or (ideally) per-query credit attribution.
- **Time zone & reconciliation:** Snowflake notes that reconciliation with `ORGANIZATION_USAGE` requires session timezone = UTC; mismatches can cause apparent deltas.
- **Billed vs metered:** using `CREDITS_USED` directly will not match billing due to cloud services adjustment; any UI must label this clearly.

## Links / references
- https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
- https://docs.snowflake.com/en/sql-reference/account-usage/query_history
- https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
