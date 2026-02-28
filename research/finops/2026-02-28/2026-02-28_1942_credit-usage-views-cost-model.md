# Research: FinOps - 2026-02-28

**Time:** 19:42 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for up to **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributed to query execution, excluding idle time). [1]
2. The `CREDITS_USED` column in `WAREHOUSE_METERING_HISTORY` is the sum of compute + cloud services credits and **does not include** the cloud-services adjustment; Snowflake recommends using `METERING_DAILY_HISTORY` to determine how many credits were **actually billed**. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage at the account level for the last **365 days**, with a `SERVICE_TYPE` dimension that includes warehouses, serverless features, and other billed services (e.g., `WAREHOUSE_METERING`, `SERVERLESS_TASK`, `SNOWPARK_CONTAINER_SERVICES`, etc.). [2]
4. Account Usage views commonly have **latency**; for `WAREHOUSE_METERING_HISTORY`, latency is up to **180 minutes** (3h) generally, but `CREDITS_USED_CLOUD_SERVICES` can lag up to **6 hours**. [1]
5. When reconciling `ACCOUNT_USAGE` data with corresponding `ORGANIZATION_USAGE` views, Snowflake instructs you to set the session timezone to **UTC** before querying. [1]
6. For “compute cost exploration,” Snowflake points to two primary analytics-ready schemas: `ACCOUNT_USAGE` (single account) and `ORGANIZATION_USAGE` (org-wide). Snowflake also exposes `USAGE_IN_CURRENCY_DAILY` for currency conversion using the daily price of a credit. [3]
7. The Information Schema table function `WAREHOUSE_METERING_HISTORY(...)` returns hourly credit usage for the last **6 months** and warns that for lengthy time periods / many warehouses it might be incomplete; Snowflake recommends using `ACCOUNT_USAGE` for completeness. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly per-warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to separate query-attributed vs idle usage. Latency notes; 365d retention. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by `SERVICE_TYPE` / `ENTITY_TYPE` / `NAME`; good for serverless + cross-feature spend breakdown. Latency notes. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to compute *billed* cloud services credits via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (doc referenced from `WAREHOUSE_METERING_HISTORY`). [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide hourly per-warehouse credits; latency up to 24h (org usage). Mentioned as reconciliation target. [1] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | 6-month window; may be incomplete for large multi-WH queries; requires `MONITOR USAGE` and `ACCOUNTADMIN`/granted roles. [4] |
| `...USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Converts credits to currency using daily credit price (Snowflake recommendation for currency reporting). [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle-time cost leaderboard (per warehouse)**
   - Use `WAREHOUSE_METERING_HISTORY` to compute `(credits_used_compute - credits_attributed_compute_queries)` per warehouse as a first-pass “idle cost” indicator and show trend + outliers.
2. **Service-type spend breakdown (hourly) with explainability**
   - Use `METERING_HISTORY` `SERVICE_TYPE` + `ENTITY_TYPE/NAME` to show where non-warehouse credits are going (serverless features, SCS, etc.), with a drill-down link to the underlying object name/ID when available.
3. **Reconciliation mode (account vs org)**
   - Build a “reconcile spend” workflow that sets expectations about latency differences and enforces UTC time alignment when comparing `ACCOUNT_USAGE` and `ORGANIZATION_USAGE`.

## Concrete Artifacts

### Artifact: Canonical hourly credit model (warehouse + service-type) for a FinOps app

Goal: provide a single *hourly* fact table/view that powers dashboards:
- Warehouse hourly credits (compute, cloud services, query-attributed, estimated idle)
- Account-level hourly credits by `SERVICE_TYPE` (serverless + cross-feature)

**Draft SQL (view-based) – starting point**

```sql
-- NOTE: This is a logical model for the app. In practice:
-- - Wrap this with incremental materialization (task/stream) or dynamic table
-- - Expect ACCOUNT_USAGE latency (3h / 6h for some columns)
-- - Use UTC when reconciling with ORG_USAGE

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Warehouse hourly credits with estimated idle credits
CREATE OR REPLACE VIEW FINOPS.V_WH_CREDITS_HOURLY AS
SELECT
  start_time::timestamp_ltz            AS hour_start,
  end_time::timestamp_ltz              AS hour_end,
  warehouse_id,
  warehouse_name,
  credits_used                         AS credits_used_total,
  credits_used_compute                 AS credits_used_compute,
  credits_used_cloud_services          AS credits_used_cloud_services,
  credits_attributed_compute_queries   AS credits_attrib_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_est_idle_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_id > 0;  -- skip pseudo-VWs such as "CLOUD_SERVICES_ONLY"

-- 2) Account hourly credits by service type (covers serverless + other features)
CREATE OR REPLACE VIEW FINOPS.V_SERVICE_CREDITS_HOURLY AS
SELECT
  start_time::timestamp_ltz   AS hour_start,
  end_time::timestamp_ltz     AS hour_end,
  service_type,
  entity_type,
  entity_id,
  name,
  database_name,
  schema_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY;

-- Example downstream query: top warehouses by idle credits (last 14 days)
SELECT
  warehouse_name,
  SUM(credits_est_idle_compute) AS idle_credits_14d
FROM FINOPS.V_WH_CREDITS_HOURLY
WHERE hour_start >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 2 DESC
LIMIT 25;
```

Why this artifact matters:
- `WAREHOUSE_METERING_HISTORY` explicitly supports idle-time estimation using `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. [1]
- `METERING_HISTORY` provides the cross-feature `SERVICE_TYPE` lens needed for a full FinOps picture beyond warehouses. [2]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Using `CREDITS_USED` from `WAREHOUSE_METERING_HISTORY` to represent “billed credits” is incorrect because cloud-services adjustments aren’t applied. | Misstated billable cost; reconciliation issues with invoices. | Use `ACCOUNT_USAGE.METERING_DAILY_HISTORY` and apply adjustments (Snowflake indicates this is needed for billed credits). [1] |
| Latency (3h/6h) in `ACCOUNT_USAGE` views means dashboards can look “wrong” in near-real-time. | Users lose trust; false alarms. | Surface data-freshness banners and use “as of” timestamps; optionally supplement with Information Schema table functions for last-hours views (with caveats). [1][4] |
| Org-wide reconciliation requires UTC alignment; otherwise hour boundaries won’t match. | Bad comparisons across org vs account; off-by-one-day graphs. | Enforce `ALTER SESSION SET TIMEZONE='UTC'` for reconciliation queries. [1] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` may be incomplete for long ranges / many warehouses. | Missing hours => incorrect trends. | Use it only for short windows; prefer `ACCOUNT_USAGE` for longer ranges. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Pull + summarize `ACCOUNT_USAGE.METERING_DAILY_HISTORY` specifics (especially `CREDITS_ADJUSTMENT_CLOUD_SERVICES`) to define a **billable credits** metric.
- Identify the minimal privileges required for a Native App to read these views (likely via grants/roles + `MONITOR USAGE`) and how this changes under Native App security boundaries.
- Extend the model with query-level attribution (`QUERY_ATTRIBUTION_HISTORY` + `QUERY_HISTORY`) for “top queries/cost centers” drill-down (referenced in cost exploration docs). [3]
