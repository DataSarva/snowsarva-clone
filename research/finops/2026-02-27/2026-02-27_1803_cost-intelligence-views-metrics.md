# Research: FinOps - 2026-02-27

**Time:** 18:03 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse (or all warehouses) for the last **365 days**, and `CREDITS_USED` is `CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES` but **does not include the cloud services “adjustment”** (so it may exceed billed credits). Snowflake points to `METERING_DAILY_HISTORY` for billed credits. (Source: Snowflake docs)  
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (execution-only) and explicitly notes **warehouse idle time is not included** in that column; an example computes idle cost as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`. (Source: Snowflake docs)  
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` provides query history for **365 days**, while the similarly named **Information Schema** table function `QUERY_HISTORY` restricts results to **7 days**. (Source: Snowflake docs)  
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute cost attribution** for the last **365 days**, but: (a) attribution excludes warehouse idle time, cloud services, storage, data transfer, serverless features, AI token costs, etc.; (b) latency may be **up to 8 hours**; (c) very short queries (≤ ~100ms) are not included; and (d) complete data availability begins **mid-Aug 2024**. (Source: Snowflake docs)  
5. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` returns **daily** organization usage in **credits and currency** with a billing-oriented dimension set (e.g., `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`). Latency may be **up to 72 hours** and daily figures can change until month close due to adjustments. (Source: Snowflake docs)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | ACCOUNT_USAGE | Hourly warehouse credits; `CREDITS_USED` not cloud-services adjusted; includes execution-only attribution (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`) enabling idle estimate as residual. Latency up to 3h (and cloud services up to 6h) per doc. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | ACCOUNT_USAGE | Query metadata (365d). Info Schema `QUERY_HISTORY` table function is 7d only. Useful dimensions: `QUERY_TAG`, `ROLE_TYPE`, warehouse, bytes scanned, queued times, etc. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | ACCOUNT_USAGE | Per-query compute-credit attribution (execution-only). Latency up to 8h; excludes idle and non-warehouse costs; short queries omitted. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | ORG_USAGE | Hourly warehouse credits across org accounts (365d). Latency up to 24h. Similar “not adjusted” billing caveat. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | view | ORG_USAGE | Daily org usage in currency; latency up to 72h; includes adjustments and a richer billing taxonomy. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Idle burn” KPI per warehouse** (and trend): compute hourly idle credits as `credits_used_compute - credits_attributed_compute_queries`, with doc-backed caveats (latency + “not adjusted” vs billed). Output: top idle warehouses + idle % over time.
2. **Query-tag showback with honest coverage metrics**: show `QUERY_ATTRIBUTION_HISTORY` cost by `QUERY_TAG` and explicitly track **coverage %** (e.g., missing ≤100ms queries; latency; pre-mid-Aug-2024 gaps). Output: “cost attributed” vs “unattributed/idle residual.”
3. **Org-level billing drilldown (currency)**: ingest `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` into app-managed tables to power cross-account dashboards and to reconcile why “credits used” views differ from “billed” usage (adjustments + month close).

## Concrete Artifacts

### Artifact: Daily cost rollup model (credits + currency), with idle residual allocation

Goal: create a consistent *FinOps* daily grain table for the Native App that can power dashboards:
- **Credits** (near-real-time) from `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` and `QUERY_ATTRIBUTION_HISTORY`
- **Currency / billed-facing** daily usage from `ORG_USAGE.USAGE_IN_CURRENCY_DAILY`

Key design choice (doc-backed): `QUERY_ATTRIBUTION_HISTORY` excludes idle and non-warehouse costs; therefore we treat it as *execution cost* only and allocate *warehouse idle residual* separately.

```sql
-- FINOPS_DAILY_COST_V1 (draft)
-- Assumptions:
--   * Run in each account for ACCOUNT_USAGE views.
--   * For ORG_USAGE views, run in the org-level context where accessible.
--   * Timezones: ORG_USAGE uses UTC dates; ACCOUNT_USAGE timestamps are local TZ by default.
--     Align by setting session timezone = UTC when reconciling.

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Hourly warehouse credits (compute vs attributed execution) -> daily
WITH wh_hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS usage_day,
    warehouse_name,
    SUM(credits_used_compute) AS wh_compute_credits,
    SUM(credits_attributed_compute_queries) AS query_exec_credits,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('DAY', -35, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),

-- 2) Query execution credits by tag -> daily
-- NOTE: per docs, this excludes idle time and various other costs.
qah_daily AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS usage_day,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '<unset>') AS query_tag,
    SUM(credits_attributed_compute) AS exec_compute_credits,
    SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('DAY', -35, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),

-- 3) Allocate idle residual back to tags proportionally by exec credits (optional)
qah_daily_with_idle_alloc AS (
  SELECT
    q.usage_day,
    q.warehouse_name,
    q.query_tag,
    q.exec_compute_credits,
    q.qas_credits,
    w.idle_compute_credits,
    CASE
      WHEN SUM(q.exec_compute_credits) OVER (PARTITION BY q.usage_day, q.warehouse_name) > 0
      THEN w.idle_compute_credits * (q.exec_compute_credits /
           SUM(q.exec_compute_credits) OVER (PARTITION BY q.usage_day, q.warehouse_name))
      ELSE NULL
    END AS idle_allocated_to_tag_credits
  FROM qah_daily q
  JOIN wh_hourly w
    ON w.usage_day = q.usage_day
   AND w.warehouse_name = q.warehouse_name
)

SELECT *
FROM qah_daily_with_idle_alloc;

-- Separate org-level daily billed usage (currency) source:
--   snowflake.organization_usage.usage_in_currency_daily
-- Join strategy depends on whether the app runs per-account or can centrally access ORG_USAGE.
```

Why this is valuable:
- Uses doc-provided columns and doc-provided method for idle estimate.
- Produces both “execution showback” and “idle burn” so the UI can present an honest decomposition.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `CREDITS_USED` in metering views is not “billed credits” due to cloud services adjustment. | Mis-match between showback credits and billing statement can confuse users. | Pair with `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` and/or `METERING_DAILY_HISTORY` for billed reconciliation; label metrics clearly. (Doc-backed caveat.) |
| Idle residual (`credits_used_compute - credits_attributed_compute_queries`) is only a warehouse-level estimate; per-query attribution excludes idle and short queries. | Any tag-level idle allocation is heuristic. | Present idle as separate bucket by default; only allocate with clear “estimated allocation” labeling + coverage stats. (Doc-backed exclusions.) |
| Timezone mismatches between ACCOUNT_USAGE (local timestamps) and ORG_USAGE (UTC dates) can break reconciliation across schemas. | Incorrect day-level joins and misleading variance analysis. | Enforce `ALTER SESSION SET TIMEZONE = UTC` when comparing account usage to org usage; add automated checks. (Doc explicitly calls out UTC for reconciliation.) |
| View latencies are non-trivial (3–6h for warehouse metering columns; up to 8h for query attribution; 24h for org wh metering; 72h for org currency daily). | “Real-time” dashboards will look incomplete; alerts could fire late. | Design UI with freshness indicators; compute “data completeness” windows per source. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
5. https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Decide the product default: **keep idle as a first-class bucket** vs allocating it to tags/cost centers (and how we communicate estimation).
- Add a **freshness/completeness** widget per metric (based on documented latencies) so customers trust the numbers.
- Extend this model to cover non-warehouse service types from `USAGE_IN_CURRENCY_DAILY` (serverless features, storage, data transfer) with a canonical service taxonomy for the app.
