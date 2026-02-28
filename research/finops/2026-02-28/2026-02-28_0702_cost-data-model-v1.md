# Research: FinOps - 2026-02-28

**Time:** 07:02 UTC  
**Topic:** Snowflake FinOps Cost Optimization (data sources + attribution primitives for a Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake exposes cost/usage data through analytics-ready views primarily in `SNOWFLAKE.ACCOUNT_USAGE` (single account) and `SNOWFLAKE.ORGANIZATION_USAGE` (all accounts in an org), and these are intended for building custom reporting beyond Snowsight dashboards. 
   - Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. **Billed** cloud services credits are adjusted daily: cloud services consumption is charged only if daily cloud services credits exceed **10%** of daily warehouse usage; most dashboards/views show consumed credits *without* applying that billing adjustment. To determine billed compute credits, query `METERING_DAILY_HISTORY`. 
   - Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credit attribution** (last 365 days), but explicitly excludes warehouse **idle time** and excludes very short queries (≈<=100ms). Latency can be up to ~8 hours.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` is the warehouse-level hourly credit usage history (retention typically up to 1 year, with view latency). The similarly named **Information Schema table function** `WAREHOUSE_METERING_HISTORY(...)` is limited to last ~6 months and may be incomplete over long multi-warehouse ranges; the docs recommend `ACCOUNT_USAGE` for complete history.
   - Sources: https://docs.snowflake.com/en/user-guide/cost-exploring-compute and https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
5. Access to `SNOWFLAKE.ACCOUNT_USAGE` is not automatic for all roles; Snowflake recommends granting access via **SNOWFLAKE database roles** (e.g., `USAGE_VIEWER`, `GOVERNANCE_VIEWER`) or `IMPORTED PRIVILEGES`. Also, avoid `SELECT *` because Snowflake-specific views are subject to change.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Use to compute **billed** cloud services credits via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (daily). Mentioned as billing reconciliation primitive. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits across warehouses/serverless/cloud services (filter `SERVICE_TYPE`). Mentioned in compute-cost guide. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (includes cloud services portion associated with using the warehouse). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Includes `QUERY_TYPE`, `CREDITS_USED_CLOUD_SERVICES`, timings; used in example queries for cloud services analysis. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits (`CREDITS_ATTRIBUTED_COMPUTE`), excludes idle time; short queries excluded; latency up to ~8 hours. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide hourly warehouse credits; latency can be up to 24h. Useful for multi-account rollups. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | Last 6 months; may be incomplete for long/multi-warehouse ranges; requires `MONITOR USAGE`/ACCOUNTADMIN. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata/usage (shared SNOWFLAKE DB; has latency)
- `ORG_USAGE` = Organization-level usage/cost (org-wide; often higher latency)
- `INFO_SCHEMA` = Database-level info schema (no latency; different retention/coverage)

## MVP Features Unlocked

1. **“Billed vs Consumed” daily compute report**: show daily warehouse + cloud services consumed credits *and* billed credits (applying the cloud services adjustment), with drilldown to top warehouses and query-types.
2. **Query cost explorer (warehouse compute)** based on `QUERY_ATTRIBUTION_HISTORY`, with caveats (idle time excluded; short queries missing), plus optional “idle time allocation” overlay (see artifact below).
3. **Native-App-friendly grants checklist**: inside the app, run diagnostics to confirm the consumer role has `USAGE_VIEWER`/`GOVERNANCE_VIEWER` (or equivalent imported privileges) to read required `SNOWFLAKE.ACCOUNT_USAGE` views; warn about view latency and `SELECT *` stability.

## Concrete Artifacts

### Artifact: SQL draft — Daily billed compute credits + optional idle-time allocation scaffold

Goal: create two derived datasets the Native App can materialize (e.g., in an app-owned database) after the customer grants access.

1) **Daily billed compute credits** from `METERING_DAILY_HISTORY` (accounts for cloud services adjustment).

```sql
-- DAILY BILLED COMPUTE CREDITS (account-level)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- Notes:
--  - Billed cloud services = credits_used_cloud_services + credits_adjustment_cloud_services
--  - Other credit types/columns exist; this keeps it intentionally minimal.

ALTER SESSION SET TIMEZONE = 'UTC';

CREATE OR REPLACE VIEW FINOPS.DAILY_BILLED_COMPUTE_CREDITS AS
SELECT
  usage_date,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services_credits,
  (credits_used_compute + credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_compute_credits
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -90, CURRENT_DATE())
ORDER BY usage_date DESC;
```

2) **Per-query compute credits** (warehouse execution only) from `QUERY_ATTRIBUTION_HISTORY`, grouped by day + query tag.

```sql
-- QUERY COST BY TAG (WAREHOUSE EXECUTION ONLY; IDLE TIME EXCLUDED)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY

ALTER SESSION SET TIMEZONE = 'UTC';

CREATE OR REPLACE VIEW FINOPS.DAILY_QUERY_CREDITS_BY_QUERY_TAG AS
SELECT
  TO_DATE(start_time)               AS usage_date,
  COALESCE(query_tag, '(none)')     AS query_tag,
  warehouse_name,
  SUM(credits_attributed_compute)   AS attributed_compute_credits,
  SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
FROM snowflake.account_usage.query_attribution_history
WHERE start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1,2,3
ORDER BY usage_date DESC, attributed_compute_credits DESC;
```

3) **Idle time allocation scaffold** (conceptual): since `QUERY_ATTRIBUTION_HISTORY` excludes idle time, create an “unattributed credits” line item per warehouse-hour as:

```sql
-- UNATTRIBUTED (POSSIBLE IDLE) CREDITS PER WAREHOUSE-HOUR
-- Idea: compare warehouse metering to sum of per-query attribution in the same hour.
-- Caveats:
--  - timezones must align
--  - QUERY_ATTRIBUTION_HISTORY latency up to ~8h; WAREHOUSE_METERING_HISTORY also has latency
--  - attribution may not perfectly reconcile due to concurrency/weighting, excluded short queries, etc.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH q_hour AS (
  SELECT
    warehouse_id,
    DATE_TRUNC('hour', start_time) AS start_hour,
    SUM(credits_attributed_compute) AS q_attributed_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
  GROUP BY 1,2
), w_hour AS (
  SELECT
    warehouse_id,
    start_time AS start_hour,
    credits_used_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
)
SELECT
  w.warehouse_id,
  w.start_hour,
  w.credits_used_compute,
  COALESCE(q.q_attributed_credits, 0) AS q_attributed_credits,
  GREATEST(w.credits_used_compute - COALESCE(q.q_attributed_credits, 0), 0) AS unattributed_compute_credits
FROM w_hour w
LEFT JOIN q_hour q
  ON q.warehouse_id = w.warehouse_id
 AND q.start_hour = w.start_hour
ORDER BY w.start_hour DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `METERING_DAILY_HISTORY` is sufficient to compute "billed compute" for the app's needs | Could miss other billed components (serverless, storage, data transfer) depending on product scope | Expand scope with additional billing/cost views once we pick MVP (compute-only vs total). Start with compute-only intentionally. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time + short queries | Per-query cost rollups won’t reconcile to warehouse metering; could confuse users | UI must label “execution-only”; optionally show “unattributed/idle” overlay using metering delta scaffold. |
| View latency (2h–8h+ for various ACCOUNT_USAGE views) | Near-real-time dashboards can be misleading | Add “data freshness” banner derived from `MAX(start_time)` and documented latencies. |
| Native App access to `SNOWFLAKE.ACCOUNT_USAGE` depends on consumer grants | App may fail without clear error messages | Build a setup wizard: verify required grants/DB roles (`USAGE_VIEWER`, `GOVERNANCE_VIEWER`) and list missing privileges. |

## Links & Citations

1. Exploring compute cost (billing adjustment, cost schemas, recommended views): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. QUERY_ATTRIBUTION_HISTORY view (per-query credits, latency, exclusions): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Account Usage overview + access/grants guidance + avoid `SELECT *`: https://docs.snowflake.com/en/sql-reference/account-usage
4. WAREHOUSE_METERING_HISTORY table function (info schema, 6-month note): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Decide MVP scope: compute-only vs include storage + data transfer; then enumerate additional `ACCOUNT_USAGE`/`ORG_USAGE` objects to ingest.
- Validate whether Snowflake Native Apps in consumer accounts can read `SNOWFLAKE.ACCOUNT_USAGE.*` directly under app roles, or must rely on customer-created secure views / share-backed staging (depends on app security model). If uncertain, spike a minimal Native App that selects from `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` after granting `USAGE_VIEWER`.
- Add a product doc section: “Consumed vs billed credits” and “Query-attributed vs metered (idle) credits”.
