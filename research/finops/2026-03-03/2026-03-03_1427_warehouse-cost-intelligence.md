# Research: FinOps - 2026-03-03

**Time:** 14:27 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for up to **365 days** (1 year) and includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed credits only; excludes idle). [2]
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` returns **hourly** credit usage for an account for up to **365 days**, and its `SERVICE_TYPE` allows breaking down costs across warehouses and many serverless features (e.g., `AUTO_CLUSTERING`, `PIPE`, `SEARCH_OPTIMIZATION`, `SNOWPARK_CONTAINER_SERVICES`, `SNOWPIPE_STREAMING`, etc.). [3]
3. Cloud services credits are **not necessarily billed**: cloud services usage is charged only if daily cloud services consumption exceeds **10%** of daily virtual warehouse usage; many views (and Snowsight) show consumed credits without this daily billing adjustment. For billed compute credits, use `METERING_DAILY_HISTORY`. [1]
4. The `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` *table function* returns hourly warehouse credits for a specified date range, but only for the last **6 months**; Snowflake notes it may not return a complete dataset for long ranges / multiple warehouses and recommends using the Account Usage view for completeness. Access requires `ACCOUNTADMIN` or a role granted global `MONITOR USAGE`. [4]
5. Account Usage views have latency: for `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, latency can be up to **180 minutes**, except `CREDITS_USED_CLOUD_SERVICES` which can be up to **6 hours**. [2]
6. To reconcile an Account Usage cost view with the corresponding `ORGANIZATION_USAGE` view, Snowflake instructs setting the session timezone to `UTC` before querying. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly per-warehouse credits (1 year). Latency up to 3h; cloud-services column up to 6h. Contains `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to estimate idle vs active. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account-level metering across many `SERVICE_TYPE`s; useful for serverless + warehouse mix attribution. Latency up to 3h; cloud-services up to 6h; Snowpipe Streaming up to 12h. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to compute *billed* credits because cloud-services daily adjustment applies; referenced by Snowflake docs as source of truth for billed compute credits. [1] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFORMATION_SCHEMA` | Hourly warehouse credits, but only last 6 months and may be incomplete for long/multi-warehouse queries. Requires `MONITOR USAGE` privilege (or ACCOUNTADMIN). [4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORGANIZATION_USAGE` | Hourly warehouse credits across all org accounts (1 year). Use for multi-account FinOps rollups; reconcile with Account Usage by setting session TZ to UTC. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Idle burn” leaderboard per warehouse**: compute `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` and rank warehouses by idle cost; link to recommended remediation (autosuspend, schedule changes, right-sizing). [2]
2. **Cloud-services ratio detector**: for each warehouse, compute `SUM(CREDITS_USED_CLOUD_SERVICES)/SUM(CREDITS_USED)` over last 30 days and flag warehouses where ratio exceeds 10% (Snowflake explicitly calls this an investigation starting point). [1]
3. **Cross-feature metering breakdown**: build a daily/hourly “FinOps Overview” page that trends `METERING_HISTORY` by `SERVICE_TYPE` so admins can see whether cost is shifting from warehouses to serverless (e.g., Search Optimization, Snowpipe, Auto-clustering, SCS). [3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Warehouse cost intelligence (idle burn + anomaly + cloud-services ratio)

```sql
-- Assumptions:
-- - Run as a role that can read SNOWFLAKE.ACCOUNT_USAGE (e.g., with IMPORTED PRIVILEGES / Snowflake DB roles).
-- - Remember: some ACCOUNT_USAGE views have latency up to hours; don't use for “real-time” alerting.

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Idle burn by warehouse (last 30 days)
-- Snowflake documents this pattern: idle ~= credits_used_compute - credits_attributed_compute_queries. [2]
WITH wh AS (
  SELECT
    warehouse_name,
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_id > 0  -- skip pseudo warehouses like "CLOUD_SERVICES_ONLY" in some examples [1]
  GROUP BY 1, 2
)
SELECT
  warehouse_name,
  SUM(credits_used_compute) AS credits_used_compute_30d,
  SUM(credits_attributed_compute_queries) AS credits_attributed_30d,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits_30d,
  IFF(SUM(credits_used_compute) = 0, NULL,
      (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / SUM(credits_used_compute)
  ) AS idle_ratio_30d
FROM wh
GROUP BY 1
ORDER BY idle_credits_30d DESC;


-- 2) Cloud services ratio by warehouse (last 30 days)
-- Snowflake suggests using this as a starting point; investigate if cloud-services ratio is high. [1]
SELECT
  warehouse_name,
  SUM(credits_used) AS credits_used_total,
  SUM(credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(credits_used_cloud_services) / NULLIF(SUM(credits_used), 0) AS cloud_services_ratio
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND credits_used_cloud_services > 0
GROUP BY 1
ORDER BY cloud_services_ratio DESC;


-- 3) Daily anomaly detection vs rolling baseline (simple z-score style)
-- Uses daily sums then compares to rolling mean/stddev per warehouse.
WITH daily AS (
  SELECT
    warehouse_name,
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used) AS credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -120, CURRENT_TIMESTAMP())
    AND warehouse_id > 0
  GROUP BY 1, 2
), stats AS (
  SELECT
    warehouse_name,
    usage_date,
    credits_used,
    AVG(credits_used) OVER (
      PARTITION BY warehouse_name
      ORDER BY usage_date
      ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) AS mean_prev_30,
    STDDEV_SAMP(credits_used) OVER (
      PARTITION BY warehouse_name
      ORDER BY usage_date
      ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) AS std_prev_30
  FROM daily
)
SELECT
  warehouse_name,
  usage_date,
  credits_used,
  mean_prev_30,
  std_prev_30,
  (credits_used - mean_prev_30) / NULLIF(std_prev_30, 0) AS zscore
FROM stats
QUALIFY mean_prev_30 IS NOT NULL
    AND std_prev_30 IS NOT NULL
    AND zscore >= 3
ORDER BY zscore DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Account Usage latency (up to ~3h for many views; some columns longer) means near-real-time alerting can be noisy/missed. | Alerts/near-real-time dashboards may mislead users. | Confirm by comparing recent usage in Snowsight vs `ACCOUNT_USAGE` timestamps and documenting expected delay windows. [2][3] |
| Cloud services billing adjustment (10% rule) means consumed credits != billed credits. | If we report “cost” from consumed credits, we may overstate billed spend. | For billed compute credits, base “invoice-aligned” summaries on `METERING_DAILY_HISTORY` as recommended. [1] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` is limited to last 6 months and may be incomplete for long/multi-warehouse ranges. | Customers using INFO_SCHEMA function for yearly trends will get partial data. | Prefer `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` for year-long and multi-warehouse reporting. [4] |
| Cross-schema reconciliation requires UTC session TZ (Account Usage vs Organization Usage). | Org-wide rollups may not match single-account dashboards if TZ differs. | Always run `ALTER SESSION SET TIMEZONE=UTC` in reconciliation queries, and document it in app-generated SQL. [2] |

## Links & Citations

1. Snowflake Docs: Exploring compute cost (cloud services billed only if >10% of daily warehouse usage; use METERING_DAILY_HISTORY for billed credits; example queries incl. cloud-services ratio & pseudo-VW filter) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. Snowflake Docs: `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view (columns, latency, idle-cost example, UTC reconciliation note) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake Docs: `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` view (hourly account credits; service_type enumeration; latency notes) — https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Snowflake Docs: `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` table function (6-month window; MONITOR USAGE requirement; output cols) — https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Add a second research pass focused on **billed-vs-consumed** reconciliation patterns (METERING_DAILY_HISTORY + USAGE_IN_CURRENCY_DAILY) and what’s feasible inside a Native App without elevated privileges.
- Draft an ADR for the app’s cost model: which dashboards are “consumed credits” vs “billed credits,” and how to label them to avoid FinOps confusion.
- Explore `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (mentioned in compute-cost docs) for per-query attribution and tag-based slicing to complement idle burn.
