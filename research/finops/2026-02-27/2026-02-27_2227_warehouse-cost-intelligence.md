# Research: FinOps - 2026-02-27

**Time:** 22:27 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the **last 365 days**, including `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`; `CREDITS_USED` is the sum and can be **greater than billed credits** because cloud services billing is adjusted elsewhere. (Docs)  
2. In `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, latency is **up to 180 minutes (3h)** for most columns, but `CREDITS_USED_CLOUD_SERVICES` can have **up to 6h** latency; `READER_ACCOUNT_USAGE` can be up to **24h**. (Docs)  
3. `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` in `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes only **credits attributed to query execution** and **excludes warehouse idle time**, which enables an **idle credits estimate** as `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` over a window. (Docs example)  
4. Cloud services layer usage is **billed only if** daily cloud services consumption exceeds **10% of daily virtual warehouse usage**; to see what was actually billed, query `METERING_DAILY_HISTORY` and its cloud services adjustment fields. (Docs)  
5. When reconciling Account Usage cost views with Organization Usage equivalents, Snowflake recommends setting the session timezone to **UTC** before querying Account Usage views. (Docs)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse (past 365d). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to estimate idle. Latency up to 3h; cloud services column up to 6h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily compute credits + cloud services adjustment to derive **billed** cloud services; recommended for billed reconciliation. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by service type (warehouses/serverless/cloud services/etc.); use to build an hourly “service ledger”. Mentioned in compute cost docs. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Used for drilling into query drivers and cloud services by query type; also used in quickstart-style “approximate” allocation joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.SESSIONS` | View | `ACCOUNT_USAGE` | Used to map `QUERY_HISTORY` to `CLIENT_APPLICATION_ID` for “partner tools consuming credits” approximation. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORGANIZATION_USAGE` | Hourly warehouse credits across accounts in org; higher latency (up to 24h) and requires UTC reconciliation for comparisons. |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits for Snowflake Native Apps in an account (useful for app-level FinOps). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse idle cost KPI**: implement “idle credits” per warehouse per day/week as `CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (with clear latency + interpretation notes).
2. **Cloud services pressure indicator**: compute `percent_cloud_services = SUM(CREDITS_USED_CLOUD_SERVICES)/SUM(CREDITS_USED)` per warehouse over trailing 30d and alert on sustained >10% (docs explicitly highlight this ratio as an investigation starting point).
3. **Spend anomaly shortlist**: implement a lightweight anomaly query that compares daily warehouse credits vs a trailing 7-day average and emits “candidate anomalies” for review.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Warehouse cost intelligence (idle + cloud services ratio + anomaly candidates)

```sql
-- WAREHOUSE COST INTELLIGENCE (draft)
-- Goal: a single daily table you can feed into a FinOps dashboard.
-- Sources: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   * Hourly data; we roll up to day.
--   * Idle estimate relies on docs: CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes idle time.
--   * Cloud services credits can lag up to ~6 hours; overall view up to ~3 hours.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time)                                AS start_hour,
    TO_DATE(start_time)                                           AS usage_date,
    warehouse_id,
    warehouse_name,
    credits_used                                                   AS credits_used_total,
    credits_used_compute                                           AS credits_used_compute,
    credits_used_cloud_services                                    AS credits_used_cloud_services,
    credits_attributed_compute_queries                             AS credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -45, CURRENT_TIMESTAMP())
    AND warehouse_id > 0   -- skip pseudo VWs like CLOUD_SERVICES_ONLY per Snowflake examples
),
by_day AS (
  SELECT
    usage_date,
    warehouse_name,
    SUM(credits_used_total)                                       AS credits_total,
    SUM(credits_used_compute)                                     AS credits_compute,
    SUM(credits_used_cloud_services)                              AS credits_cloud_services,
    SUM(credits_attributed_compute_queries)                       AS credits_attributed_queries,
    /* Idle compute estimate (docs example pattern) */
    GREATEST(0, SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS credits_idle_est
  FROM hourly
  GROUP BY 1,2
),
with_7d_avg AS (
  SELECT
    usage_date,
    warehouse_name,
    credits_total,
    credits_compute,
    credits_cloud_services,
    credits_attributed_queries,
    credits_idle_est,
    AVG(credits_total) OVER (
      PARTITION BY warehouse_name
      ORDER BY usage_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS credits_total_prev_7d_avg
  FROM by_day
)
SELECT
  usage_date,
  warehouse_name,
  credits_total,
  credits_compute,
  credits_cloud_services,
  credits_attributed_queries,
  credits_idle_est,
  IFF(credits_total = 0, NULL, credits_cloud_services / credits_total) AS percent_cloud_services,
  credits_total_prev_7d_avg,
  IFF(
    credits_total_prev_7d_avg IS NULL OR credits_total_prev_7d_avg = 0,
    NULL,
    (credits_total / credits_total_prev_7d_avg) - 1
  ) AS pct_over_prev_7d_avg,
  /* Heuristic flag: big day + >=50% over trailing 7d average (mirrors Snowflake quickstart-style thresholds) */
  IFF(credits_total > 100 AND pct_over_prev_7d_avg >= 0.50, TRUE, FALSE) AS anomaly_candidate
FROM with_7d_avg
ORDER BY usage_date DESC, credits_total DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Idle credits” computed via `credits_used_compute - credits_attributed_compute_queries` assumes the residual is *only* idle; other attribution nuances could exist in edge cases. | Misleading KPI could drive wrong actions (e.g., blaming idle when it’s attribution gaps). | Validate against Snowflake example + compare to warehouse load/queueing metrics (e.g., `WAREHOUSE_LOAD_HISTORY`) and a sample of known workloads. |
| Cloud services credits are not the same as cloud services billed credits (10% daily free threshold + adjustments). | Overstating true billed costs can cause alarm fatigue. | Join to `METERING_DAILY_HISTORY` to compute billed cloud services (docs). |
| Latency (3h typical; 6h for `CREDITS_USED_CLOUD_SERVICES`) can make near-real-time dashboards look wrong. | Users distrust dashboard. | Explicit “data freshness” indicator; optionally backfill and only alert on fully-latent windows (e.g., T-8h). |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. https://www.snowflake.com/en/developers/guides/resource-optimization-usage-monitoring/
4. https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Extend the artifact to incorporate **query tags** / object tags for allocation (join strategy depends on whether warehouses are dedicated vs shared).
- Add a small “data freshness” table derived from max `START_TIME` loaded per view to avoid alerting on incomplete windows.
- Decide whether the FinOps Native App should store this as a **derived daily fact** (materialized table) vs on-the-fly view for each tenant.
