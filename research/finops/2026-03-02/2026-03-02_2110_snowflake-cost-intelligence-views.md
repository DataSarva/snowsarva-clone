# Research: FinOps - 2026-03-02

**Time:** 21:10 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly credit usage** for one or all warehouses for the **last 365 days**, including separate compute vs cloud services credit columns and an “attributed to queries” column that **excludes idle time**. 
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is a sum of compute + cloud services credits and **may be greater than billed credits** because it does not incorporate the **cloud services billing adjustment**; billed reconciliation should use `METERING_DAILY_HISTORY`. 
3. Account Usage views have **non-trivial latency** (e.g., `WAREHOUSE_METERING_HISTORY` can lag up to ~180 minutes, and `CREDITS_USED_CLOUD_SERVICES` up to ~6 hours). Apps must be built to handle late-arriving data.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` provides query-level dimensions useful for attribution and analysis (e.g., `WAREHOUSE_NAME`, `ROLE_NAME`, `QUERY_TAG`, `EXECUTION_TIME`, `BYTES_SCANNED`, queueing times, etc.), plus a per-query `CREDITS_USED_CLOUD_SERVICES` field.
5. `SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE` provides **daily** storage usage (bytes) across the account for the last 365 days, including table storage (incl. Time Travel), stage bytes, and fail-safe bytes; Snowflake recommends using **UTC session timezone** for date consistency.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which excludes idle time; latency up to ~3h (cloud services column up to ~6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | `ACCOUNT_USAGE` | Query-level facts + dimensions including `QUERY_TAG`, `WAREHOUSE_NAME`, timings, bytes scanned, and `CREDITS_USED_CLOUD_SERVICES` (not billed-adjusted). |
| `SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE` | view | `ACCOUNT_USAGE` | Daily storage bytes, incl. stage/fail-safe; latency up to ~2h; dates are local-time unless session timezone set (UTC recommended). |
| `ALTER SESSION SET TIMEZONE = 'UTC'` | session setting | SQL | Recommended by Snowflake docs for reconciling across schemas and for date-based reporting consistency. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse Idle Cost Report (doc-backed):** A daily/hourly report that explicitly breaks down `idle_credits = credits_used_compute - credits_attributed_compute_queries` per warehouse, with freshness watermarking to handle view latency.
2. **“Consumed vs Billed” toggle:** Show “consumed credits” from `WAREHOUSE_METERING_HISTORY` and provide a “billed credits” reconciliation path using `METERING_DAILY_HISTORY` (not fetched in this session, but explicitly referenced by Snowflake docs).
3. **Attribution-ready query enrichment:** Persist a slimmed fact table from `QUERY_HISTORY` keyed by `QUERY_ID` with `QUERY_TAG`, `ROLE_NAME`, `WAREHOUSE_NAME`, and key performance counters to support downstream cost allocation and root-cause.

## Concrete Artifacts

### Daily warehouse credits + idle breakdown (SQL draft)

```sql
-- Purpose
--   Build a warehouse-day cost mart that (a) captures consumed credits and
--   (b) explicitly computes idle credits from Snowflake's own columns.
--
-- Notes
--   - WAREHOUSE_METERING_HISTORY is hourly; we roll up to day.
--   - Per Snowflake docs, set session timezone to UTC for consistent date grouping.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used) AS credits_used_total,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
)
SELECT
  usage_date,
  warehouse_id,
  warehouse_name,
  credits_used_total,
  credits_used_compute,
  credits_used_cloud_services,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute
FROM wh_hourly
ORDER BY usage_date DESC, credits_used_total DESC;
```

### Optional: query-tag rollup (dimension-only) for attribution joins

```sql
-- Purpose
--   Produce a daily rollup by QUERY_TAG for explanation + allocation.
--   This does NOT directly yield compute credits (warehouse compute is metered at warehouse level),
--   but it gives a clean denominator (time, bytes, etc.) to allocate warehouse credits.

ALTER SESSION SET TIMEZONE = 'UTC';

SELECT
  DATE_TRUNC('DAY', start_time) AS usage_date,
  warehouse_name,
  COALESCE(NULLIF(query_tag, ''), '<none>') AS query_tag,
  COUNT(*) AS query_count,
  SUM(execution_time) / 1000.0 AS execution_seconds,
  SUM(bytes_scanned) AS bytes_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
  AND execution_status = 'SUCCESS'
GROUP BY 1,2,3
ORDER BY usage_date DESC, execution_seconds DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Account Usage latency (hours) means “today” is incomplete. | Dashboards/alerts may flap or undercount. | Track max(`end_time`) watermarks; only alert on completed windows; document expected lag per view. |
| `CREDITS_USED` and `QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES` may not match billed credits due to cloud services adjustments. | “True $” numbers may drift vs invoice. | Use `METERING_DAILY_HISTORY` for billed reconciliation (explicitly referenced by Snowflake docs). |
| Date grouping can differ if session timezone not standardized (local vs UTC). | Reconciliation across datasets may fail; day-level totals appear off. | Enforce `ALTER SESSION SET TIMEZONE='UTC'` in all ingestion/ETL queries. |

## Links & Citations

1. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` view (columns, latency, idle-time example, billed-recon note): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Docs — `QUERY_HISTORY` view (query-level dimensions incl. `QUERY_TAG`, timings, bytes, cloud services credits): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. Snowflake Docs — `STORAGE_USAGE` view (daily bytes, stage/fail-safe, latency, timezone guidance): https://docs.snowflake.com/en/sql-reference/account-usage/storage_usage
4. Snowflake Docs — Understanding overall cost (compute/storage/transfer + cloud services 10% rule context): https://docs.snowflake.com/en/user-guide/cost-understanding-overall

## Next Steps / Follow-ups

- Pull and cite `METERING_DAILY_HISTORY` docs (and ORG_USAGE equivalents) and draft an explicit **Consumed → Billed** reconciliation query keyed by date + service_type.
- Decide “default allocation basis” for allocating warehouse credits down to tags (execution_time vs bytes_scanned) and document it as an ADR.
- Add data quality checks: missing `warehouse_name`, `query_tag` coverage %, late-arrival monitoring, and warehouse-hour gaps.
