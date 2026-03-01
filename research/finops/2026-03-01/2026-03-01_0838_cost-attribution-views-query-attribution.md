# Research: FinOps - 2026-03-01

**Time:** 08:38 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake compute cost includes credit consumption from virtual warehouses, serverless features, and the cloud services layer; Snowflake provides both Snowsight UI and SQL-accessible usage views to analyze this cost.  
   Source: Snowflake docs “Exploring compute cost”.
2. Cloud services credits are *not always billed*; cloud services usage is charged only if daily cloud services consumption exceeds 10% of daily virtual warehouse usage. For billed credits reconciliation, Snowflake recommends querying `METERING_DAILY_HISTORY`.  
   Source: Snowflake docs “Exploring compute cost”.
3. For “cost in currency” (not just credits), Snowflake provides `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, which converts usage into currency using the daily price of a credit. It can have up to 72 hours latency and is retained indefinitely.  
   Source: Snowflake docs “USAGE_IN_CURRENCY_DAILY view”.
4. For query-level warehouse compute attribution, Snowflake provides `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`, which attributes **warehouse compute credits** to individual queries (but explicitly excludes warehouse idle time and excludes other cost categories such as cloud services, serverless, storage, and data transfer). Latency for the view can be up to eight hours, and very short queries (<= ~100ms) are not included.  
   Source: Snowflake docs “QUERY_ATTRIBUTION_HISTORY view”.
5. For warehouse-level metering, `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides hourly warehouse credit usage over the last 365 days (1 year). (Information Schema table function `WAREHOUSE_METERING_HISTORY(...)` only covers the last 6 months and may be incomplete for long ranges.)  
   Source: Snowflake docs for the `WAREHOUSE_METERING_HISTORY` view + table function.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; up to 1 year retention; includes compute + cloud services credits at warehouse-hour grain. |
| `SNOWFLAKE.INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | INFO_SCHEMA | Hourly warehouse credits for last 6 months; docs note it may be incomplete for long ranges across many warehouses; prefer ACCOUNT_USAGE for completeness. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily metering; recommended for determining credits actually billed (cloud services adjustment). |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily usage in currency; up to 72h latency; not accessible for reseller contracts; retained indefinitely. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query attributed warehouse compute credits; excludes idle time, cloud services, serverless, storage, transfer; <=~100ms queries excluded; up to ~8h latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Per-query metadata and timings; contains `QUERY_TAG` and per-query `CREDITS_USED_CLOUD_SERVICES`. Useful for cloud services analysis and joining to attribution outputs. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Join tags to warehouses/users/etc for showback/chargeback rollups. |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Credits vs Billed Credits” reconciliation widget (account level).**
   - Show `credits_used_cloud_services` and `credits_adjustment_cloud_services` from `ACCOUNT_USAGE.METERING_DAILY_HISTORY` so users see *why* Snowsight-style totals can differ from billed totals.
2. **Query-level showback module powered by `QUERY_ATTRIBUTION_HISTORY` (with explicit gaps).**
   - Surface per-query attributed compute credits and clearly label: “warehouse compute only; idle time excluded; cloud services excluded”.
3. **Org-level $ spend by account/service type using `USAGE_IN_CURRENCY_DAILY`.**
   - Provide CFO-friendly rollups (currency) with `BALANCE_SOURCE`, `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT` dimensions.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily Cost Fact Table (credits + currency + query-attribution)

Goal: create a durable “finops fact table” the Native App can query to power dashboards.

Notes:
- This intentionally keeps grains separate: org-day (currency), warehouse-hour (metering), query (attribution).
- Where grains must be joined, do it via rollups (e.g., query → day + warehouse) rather than attempting perfect per-second reconciliation.

```sql
-- Create a minimal FinOps schema for reporting artifacts.
CREATE SCHEMA IF NOT EXISTS FINOPS;

-- 1) Org-level daily $ (currency)
CREATE OR REPLACE VIEW FINOPS.ORG_DAILY_USAGE_IN_CURRENCY AS
SELECT
  usage_date,
  organization_name,
  account_name,
  account_locator,
  region,
  currency,
  billing_type,
  rating_type,
  service_type,
  usage,
  usage_in_currency,
  is_adjustment,
  balance_source
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY;

-- 2) Account-level warehouse-hour credits (compute + cloud services at warehouse-hour grain)
CREATE OR REPLACE VIEW FINOPS.ACCOUNT_WAREHOUSE_HOURLY_METERING AS
SELECT
  start_time,
  end_time,
  warehouse_id,
  warehouse_name,
  credits_used,
  credits_used_compute,
  credits_used_cloud_services,
  credits_attributed_compute_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_id > 0; -- skip pseudo warehouses (per Snowflake examples)

-- 3) Per-query attributed compute credits (warehouse compute only; excludes idle time)
CREATE OR REPLACE VIEW FINOPS.ACCOUNT_QUERY_ATTRIBUTION AS
SELECT
  query_id,
  root_query_id,
  parent_query_id,
  warehouse_id,
  warehouse_name,
  query_parameterized_hash,
  query_tag,
  user_name,
  start_time,
  end_time,
  credits_attributed_compute,
  credits_used_query_acceleration
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY;

-- 4) Convenience rollup: attributed credits by day + warehouse + query_tag
CREATE OR REPLACE VIEW FINOPS.DAILY_ATTRIBUTED_CREDITS_BY_TAG AS
SELECT
  TO_DATE(start_time) AS usage_date,
  warehouse_name,
  COALESCE(query_tag, '∅') AS query_tag,
  SUM(credits_attributed_compute) AS credits_attributed_compute
FROM FINOPS.ACCOUNT_QUERY_ATTRIBUTION
GROUP BY 1,2,3;

-- 5) Idle-time estimate at warehouse level (hourly)
-- Snowflake docs note that credits_attributed_compute_queries excludes idle time.
CREATE OR REPLACE VIEW FINOPS.ACCOUNT_WAREHOUSE_HOURLY_IDLE_CREDITS AS
SELECT
  start_time,
  warehouse_name,
  GREATEST(
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries),
    0
  ) AS idle_compute_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_id > 0
GROUP BY 1,2;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Org-level currency view (`USAGE_IN_CURRENCY_DAILY`) has up to ~72h latency and can change until month close. | “Yesterday’s spend” dashboards can look wrong or drift. | Communicate freshness; version snapshots; reconcile at month-close. Source: USAGE_IN_CURRENCY_DAILY usage notes. |
| `QUERY_ATTRIBUTION_HISTORY` excludes warehouse idle time, cloud services credits, serverless feature credits, storage, data transfer, and AI token costs. | Query-level “true total cost” cannot be computed from this view alone. | Label outputs explicitly; pair with warehouse + cloud services analyses; optionally allocate idle at higher grain as an approximation. Source: QUERY_ATTRIBUTION_HISTORY usage notes. |
| Very short queries (<= ~100ms) are excluded from query attribution. | High-volume “tiny queries” workloads may be underrepresented in query-level views. | Add separate “tiny query” metrics from `QUERY_HISTORY` and cloud services credits by query type. Source: QUERY_ATTRIBUTION_HISTORY usage notes + Exploring compute cost example queries. |
| Information Schema `WAREHOUSE_METERING_HISTORY(...)` can be incomplete for long ranges / multi-warehouse queries; only last 6 months. | Incomplete historical reporting if INFO_SCHEMA is used as primary source. | Prefer `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` for completeness and longer retention. Source: WAREHOUSE_METERING_HISTORY table function docs. |

## Links & Citations

1. Exploring compute cost (cloud services 10% billing adjustment; recommends `METERING_DAILY_HISTORY`; lists relevant views including `QUERY_ATTRIBUTION_HISTORY`): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. `USAGE_IN_CURRENCY_DAILY` (org-level currency; columns + 72h latency + indefinite retention): https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. `QUERY_ATTRIBUTION_HISTORY` (per-query compute credits; excludes idle time and other cost classes; latency up to 8h; short queries excluded): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. `WAREHOUSE_METERING_HISTORY` view (ACCOUNT_USAGE, hourly credits, 1 year): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
5. `WAREHOUSE_METERING_HISTORY` table function (INFO_SCHEMA; last 6 months and completeness warning): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Pull the exact Snowflake docs SQL examples for “warehouse cost attribution by query tag” and adapt into a Native App-ready view (ensuring timezone handling and pseudo-warehouse filters are consistent).
- Decide on an explicit product stance for “idle cost allocation”: (a) do not allocate (most conservative), (b) allocate to query tags proportionally by attributed credits, (c) allocate to “last query before idle resume” using event history (more complex).
- Draft a UX spec for “freshness badges” (72h org-level currency latency vs ~2-6h account usage latency vs ~8h query attribution latency).
