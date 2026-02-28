# Research: FinOps - 2026-02-28

**Time:** 21:58 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**; the `CREDITS_USED` column is the sum of compute + cloud services credits and **may exceed billed credits** because it does not apply the daily cloud services billing adjustment. Use `METERING_DAILY_HISTORY` to determine what was actually billed. 
   - Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY` and `METERING_DAILY_HISTORY`. 

2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` includes only credits attributed to **query execution** and **excludes warehouse idle time**; idle credits can be estimated as `(SUM(credits_used_compute) - SUM(credits_attributed_compute_queries))` over a time window. 
   - Source: `WAREHOUSE_METERING_HISTORY` usage notes + example.

3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** billed credits by `SERVICE_TYPE` and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative) and `CREDITS_BILLED` which sums compute + cloud services + adjustment. Latency can be up to **180 minutes**.
   - Source: `METERING_DAILY_HISTORY` docs.

4. If reconciling Account Usage views with corresponding Organization Usage views, set session timezone to **UTC** before querying Account Usage views.
   - Source: `WAREHOUSE_METERING_HISTORY` + `METERING_DAILY_HISTORY` usage notes.

5. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes fields useful for cost attribution/chargeback heuristics (e.g., `WAREHOUSE_NAME`, `ROLE_NAME`, `QUERY_TAG`, times, bytes scanned, `CREDITS_USED_CLOUD_SERVICES`). The `CREDITS_USED_CLOUD_SERVICES` value may not match billed credits; billed cloud services should be reconciled via `METERING_DAILY_HISTORY`.
   - Source: `QUERY_HISTORY` docs.

6. Snowflake Native Apps have platform limitations that matter for FinOps data collection inside an app: **temporary tables or stages are not supported** (affects staging patterns), and apps do **not support failover** via replication/failover groups.
   - Source: Native Apps limitations docs.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits for 365d; latency up to 3h (cloud services up to 6h); `CREDITS_USED` != billed; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for “query execution only” attribution (no idle). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits by `SERVICE_TYPE`; includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`; latency up to 3h; set TZ=UTC to reconcile with ORG usage equivalents. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level operational fields + heuristics for chargeback (e.g., `QUERY_TAG`, `ROLE_NAME`, `WAREHOUSE_NAME`); includes `CREDITS_USED_CLOUD_SERVICES` (unadjusted). |
| Native App Framework limitations | Doc | N/A | No temp tables/stages; no failover; constraints to reflect in app architecture + ingestion design. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle compute detector (warehouse-level):** compute idle credits per warehouse per day/week using `WAREHOUSE_METERING_HISTORY` and highlight warehouses with high idle ratio. (Directly supported by Snowflake example query.)

2. **Billed-vs-used reconciliation widgets:** show (a) hourly warehouse `CREDITS_USED` vs (b) daily `CREDITS_BILLED` by service type, with explicit caveats on cloud services adjustment + latency. This avoids misleading “$” charts.

3. **Chargeback keys from query metadata:** aggregate query activity by `QUERY_TAG` and/or `ROLE_NAME` and tie it back to warehouses, creating “who drove workload” views (heuristic; needs careful messaging since per-query credits aren’t fully billed-attribution).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Canonical “credits model” views (hourly warehouse + daily billed)

```sql
-- Ensure UTC when reconciling ACCOUNT_USAGE with ORG_USAGE equivalents.
ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Hourly warehouse usage (used credits, NOT necessarily billed)
CREATE OR REPLACE VIEW FINOPS.HOURLY_WAREHOUSE_CREDITS AS
SELECT
  start_time,
  end_time,
  warehouse_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_estimated_idle_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP());

-- 2) Daily account billed credits by service type (billed credits are authoritative)
CREATE OR REPLACE VIEW FINOPS.DAILY_BILLED_CREDITS_BY_SERVICE AS
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE());

-- 3) Optional: query rollups for chargeback keys (heuristic; not a per-query billed credit)
CREATE OR REPLACE VIEW FINOPS.DAILY_QUERY_ACTIVITY_BY_TAG AS
SELECT
  TO_DATE(start_time) AS usage_date,
  warehouse_name,
  role_name,
  query_tag,
  COUNT(*) AS query_count,
  SUM(total_elapsed_time) / 1000.0 AS total_elapsed_seconds,
  SUM(bytes_scanned) AS bytes_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
GROUP BY 1,2,3,4;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Treating hourly `CREDITS_USED` as “billed” | Overstates costs (cloud services adjustments are applied daily; billed is not a pure sum of hourly values) | Always label charts as “used credits”; compute “billed credits” from `METERING_DAILY_HISTORY.CREDITS_BILLED` (daily). |
| Using `QUERY_HISTORY` aggregates for chargeback implies cost attribution | Users may misinterpret activity metrics as precise $ cost | In UI copy: “activity-based allocation”; optionally add more accurate attribution later using Snowflake attribution views (future research). |
| Native app implementation needs staging patterns | No temp tables/stages in native apps affects common ETL patterns | Use persistent app-owned schema objects; avoid temp stage patterns in stored procs/Streamlit components. |
| View latency (up to hours) | Alerts/dashboards may look “wrong” near real-time | Show freshness timestamps; avoid “real-time spend” claims. |

## Links & Citations

1. Snowflake docs: `WAREHOUSE_METERING_HISTORY` (Account Usage) — hourly warehouse credits, latency + billed caveats + idle-cost example: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake docs: `METERING_DAILY_HISTORY` (Account Usage) — daily billed credits by service type + cloud services adjustment: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Snowflake docs: `QUERY_HISTORY` (Account Usage) — query metadata fields (warehouse, role, query_tag, etc.) and cloud services credits note: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. Snowflake docs: Native Apps limitations (no temp tables/stages; no failover, etc.): https://docs.snowflake.com/en/developer-guide/native-apps/limitations

## Next Steps / Follow-ups

- Pull additional authoritative sources on **budgets/alerts** and **query-level credit attribution** (to move beyond heuristic chargeback), once web search / Parallel API is available.
- Convert the SQL drafts into an internal “foundation schema” for the Native App (secure views + governance model) and define required consumer grants for reading `SNOWFLAKE.ACCOUNT_USAGE`.
