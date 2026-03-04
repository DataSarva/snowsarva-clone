# Research: FinOps - 2026-03-04

**Time:** 16:26 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Resource monitors only apply to warehouse credit usage** (user-managed virtual warehouses + cloud services that support those warehouses). They **do not** monitor serverless features or AI services; Snowflake recommends using **budgets** for those.  
   Source: Snowflake docs — Working with resource monitors.

2. Resource monitors can be configured with **CREDIT_QUOTA**, a **reset frequency** (DAILY/WEEKLY/MONTHLY/YEARLY/NEVER), optional start/end timestamps, and **trigger actions** at thresholds (NOTIFY, SUSPEND, SUSPEND_IMMEDIATE). At least one trigger must be added for actions to occur.  
   Source: Snowflake SQL reference — CREATE RESOURCE MONITOR.

3. If you set FREQUENCY/START_TIMESTAMP on a resource monitor, the **usage reset occurs at 12:00 AM UTC**, regardless of the time-of-day in START_TIMESTAMP.  
   Source: Snowflake docs — Working with resource monitors; Snowflake SQL reference — CREATE RESOURCE MONITOR.

4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credits for warehouses (including compute + cloud services components), with view latency up to ~3 hours (and cloud services up to ~6 hours). It also provides `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only; excludes idle).  
   Source: Snowflake SQL reference — WAREHOUSE_METERING_HISTORY.

5. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`; Snowflake points to this view to compute what cloud services consumption was actually billed after the daily adjustment rules.  
   Source: Snowflake SQL reference — METERING_DAILY_HISTORY.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| RESOURCE MONITOR (object) | Object | N/A (DDL) | Warehouse-only cost guardrails; triggers: NOTIFY/SUSPEND/SUSPEND_IMMEDIATE. |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly warehouse credits (`CREDITS_USED`, `..._COMPUTE`, `..._CLOUD_SERVICES`, `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`). Latency up to ~3h; cloud services up to ~6h. |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Daily billed credits across service types; includes cloud services adjustment + `CREDITS_BILLED`. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Resource monitor “burn rate” + forecast widget (warehouse-only):** For each warehouse (or monitor), compute MTD credits used, recent trailing daily/hourly burn, and project end-of-period usage vs quota. Emit “days-to-threshold” estimates.

2. **Budget gap coverage UX:** In-app linting that detects “resource monitor configured but account spends heavily on non-warehouse services” by comparing warehouse metering vs metering_daily_history service types; recommend budgets for serverless/AI per Snowflake guidance.

3. **Idle cost minimization insights:** Use WAREHOUSE_METERING_HISTORY’s example pattern (compute minus attributed query compute) to quantify idle cost per warehouse and recommend auto-suspend settings / warehouse sizing changes.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Warehouse spend burn-rate + month-end forecast vs quota

Assumptions:
- We treat “monthly” as current calendar month in UTC.
- We forecast month-end credits using a simple trailing-window average daily burn (swap in more sophisticated models later).
- This is warehouse-only forecasting (resource monitor scope).

```sql
-- Warehouse burn rate + naive month-end forecast (credits)
-- Sources:
--   * SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly)
--   * Optionally reconcile to billed credits via METERING_DAILY_HISTORY (daily, across services)

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    WAREHOUSE_NAME,
    START_TIME,
    END_TIME,
    CREDITS_USED,
    CREDITS_USED_COMPUTE,
    CREDITS_USED_CLOUD_SERVICES
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
),
by_day AS (
  SELECT
    WAREHOUSE_NAME,
    TO_DATE(START_TIME) AS USAGE_DATE,
    SUM(CREDITS_USED) AS CREDITS_USED
  FROM hourly
  GROUP BY 1,2
),
trailing AS (
  SELECT
    WAREHOUSE_NAME,
    AVG(CREDITS_USED) AS AVG_DAILY_CREDITS_LAST_7D
  FROM by_day
  WHERE USAGE_DATE >= DATEADD('day', -7, CURRENT_DATE())
  GROUP BY 1
),
mtd AS (
  SELECT
    WAREHOUSE_NAME,
    SUM(CREDITS_USED) AS MTD_CREDITS
  FROM by_day
  GROUP BY 1
),
calendar AS (
  SELECT
    DAY(LAST_DAY(CURRENT_DATE())) AS DAYS_IN_MONTH,
    DAY(CURRENT_DATE()) AS DAY_OF_MONTH
)
SELECT
  mtd.WAREHOUSE_NAME,
  mtd.MTD_CREDITS,
  trailing.AVG_DAILY_CREDITS_LAST_7D,
  (calendar.DAYS_IN_MONTH - calendar.DAY_OF_MONTH) AS DAYS_REMAINING,
  mtd.MTD_CREDITS
    + trailing.AVG_DAILY_CREDITS_LAST_7D * (calendar.DAYS_IN_MONTH - calendar.DAY_OF_MONTH)
    AS FORECAST_MONTH_CREDITS
FROM mtd
JOIN trailing
  ON trailing.WAREHOUSE_NAME = mtd.WAREHOUSE_NAME
CROSS JOIN calendar
ORDER BY FORECAST_MONTH_CREDITS DESC;
```

How this ties into resource monitors:
- The app can fetch the monitor quota (via `SHOW RESOURCE MONITORS` parsing or via a modeled config table) and compute:
  - `FORECAST_MONTH_CREDITS / CREDIT_QUOTA` (projected %)
  - “date to 100%” under constant burn assumption
  - recommended trigger thresholds (e.g., 80/90/100)

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Resource monitors don’t cover serverless/AI services. | Forecasting based only on warehouses can understate total spend; users may misinterpret it as “total bill”. | Compare `METERING_DAILY_HISTORY` totals vs warehouse-only rollups; add UI labels + budget recommendation. |
| Using trailing 7-day average is a simplistic forecast. | False positives/negatives during spiky workloads or month-end jobs. | Add alternative forecasts (e.g., EWMA; weekday seasonality) and backtest vs historical months. |
| ACCOUNT_USAGE view latencies (hours) can delay alerts/forecasts. | The “current burn” may lag real-time usage. | Surface “data freshness” and combine with warehouse state/credit metering where possible. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/resource-monitors
2. https://docs.snowflake.com/en/sql-reference/sql/create-resource-monitor
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

## Next Steps / Follow-ups

- Add a FinOps “coverage” check: warehouse-only vs total credits billed by service type (from `METERING_DAILY_HISTORY`).
- Prototype a small “monitor/quota config” model in the app (extract from `SHOW RESOURCE MONITORS` + `SHOW WAREHOUSES`).
- Decide whether to implement forecasting as:
  - pure SQL views (app queries) vs
  - persisted daily aggregates (cheaper query cost, more stable charts).
