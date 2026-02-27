# Research: FinOps - 2026-02-27

**Time:** 0934 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake compute cost visibility can be obtained via Snowsight cost management dashboards or by querying views in `SNOWFLAKE.ACCOUNT_USAGE` and `SNOWFLAKE.ORGANIZATION_USAGE`. These views expose usage primarily in **credits**.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. **Cloud services credits are not always billed**: cloud services usage is charged only if daily cloud services consumption exceeds **10%** of daily virtual warehouse usage. Many dashboards/views show total credits consumed without applying this daily adjustment; to determine billed compute credits, query `METERING_DAILY_HISTORY`.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. For currency reporting (not just credits), Snowflake provides `USAGE_IN_CURRENCY_DAILY` (in `ORGANIZATION_USAGE`) which converts credits to currency using the **daily price of a credit**.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Snowflake frames cost management as **visibility → control → optimization**. “Control” includes budgets (warehouses + serverless) and resource monitors (warehouses), as well as query limits (e.g., terminate long-running queries) to avoid runaway spend.  
   Source: https://docs.snowflake.com/en/user-guide/cost-management-overview
5. Warehouse “query load” is calculated as the sum of query execution seconds in an interval divided by interval seconds; sustained periods where total query load is < 1 while credits are consumed indicates inefficient utilization (over-provisioning / idle burn).  
   Source: https://docs.snowflake.com/en/user-guide/warehouses-load-monitoring
6. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` logs suspend/resume/resize/spin up/down events and includes explicit “cost impact” notes in the doc for key event types. View latency can be up to ~3 hours.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_events_history

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits across compute; use to compute **billed** cloud services credits via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` + `CREDITS_USED_CLOUD_SERVICES`. Cloud services billed only if >10% threshold. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits across warehouses/serverless/cloud services (high-level). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by warehouse (includes associated cloud services cost). [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily credits + **currency cost** using daily price of credit. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Needed for query-level cost drivers + cloud services credits per query type; also used to derive load-related metrics. [1][3] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | ACCOUNT_USAGE | Events incl. autosuspend/autoresume/resize; latency up to 3 hours; can attribute cost shifts to configuration changes. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY` | View | ACCOUNT_USAGE | Serverless credits for auto-clustering (feature-specific cost view). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY` | View | ACCOUNT_USAGE | Serverless credits for materialized view refresh (feature-specific). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | ACCOUNT_USAGE | Daily credit usage for Snowflake Native Apps in an account (last 365 days). Useful for app-level FinOps reporting. [1] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Billed-vs-consumed compute model**: a daily fact table that computes (a) warehouse credits, (b) cloud services credits consumed, (c) cloud services credits actually billed (10% rule via `METERING_DAILY_HISTORY`). This is the base for trustworthy anomaly detection.  
   Sources: [1]
2. **Idle-burn detection**: identify warehouses with persistent “query load < 1” windows, then estimate savings sensitivity to changing warehouse size or autosuspend. Start with Snowsight-aligned load definition, then correlate with metering.  
   Sources: [3]
3. **Configuration-change attribution**: detect spend step-changes and link them to explicit warehouse events (resize, multi-cluster spinup, autoresume/autosuspend). This is a high-signal “why did cost spike?” explanation primitive.  
   Sources: [4]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily compute ledger with billed cloud services + simple anomaly flags

Purpose: build a minimal daily ledger to power (1) cost charts that match billing logic (esp. cloud services) and (2) anomaly detection per warehouse.

```sql
-- Daily compute ledger (account-level). Extend to ORG_USAGE by swapping schema.
-- Sources:
--  * ACCOUNT_USAGE.METERING_DAILY_HISTORY (daily credits, billed cloud services adjustment)
--  * ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly by warehouse)
--  * ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY (explanations for step changes)

WITH daily_billed AS (
  SELECT
      usage_date::date                                        AS usage_date,
      credits_used_compute                                    AS credits_used_compute_total,
      credits_used_cloud_services                             AS credits_used_cloud_services_consumed,
      credits_adjustment_cloud_services                       AS credits_adjustment_cloud_services,
      (credits_used_cloud_services + credits_adjustment_cloud_services)
                                                            AS credits_billed_cloud_services
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD('day', -60, CURRENT_DATE())
),
wh_daily AS (
  -- Roll up warehouse credits to daily. Note: warehouse_metering_history includes cloud services associated with warehouse usage.
  SELECT
      TO_DATE(start_time)                                     AS usage_date,
      warehouse_name,
      SUM(credits_used_compute)                               AS credits_used_compute_wh,
      SUM(credits_used_cloud_services)                        AS credits_used_cloud_services_wh,
      SUM(credits_used)                                       AS credits_used_total_wh
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -60, CURRENT_TIMESTAMP())
    AND warehouse_id > 0  -- skip pseudo warehouses
  GROUP BY 1, 2
),
wh_baseline AS (
  -- Simple baseline: trailing 14-day mean/stddev per warehouse.
  SELECT
      usage_date,
      warehouse_name,
      credits_used_total_wh,
      AVG(credits_used_total_wh) OVER (
        PARTITION BY warehouse_name
        ORDER BY usage_date
        ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
      )                                                       AS trailing_mean,
      STDDEV_SAMP(credits_used_total_wh) OVER (
        PARTITION BY warehouse_name
        ORDER BY usage_date
        ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
      )                                                       AS trailing_stddev
  FROM wh_daily
)
SELECT
    b.usage_date,
    w.warehouse_name,

    -- warehouse totals
    w.credits_used_compute_wh,
    w.credits_used_cloud_services_wh,
    w.credits_used_total_wh,

    -- account-level billed cloud services (useful to reconcile / explain differences)
    b.credits_used_cloud_services_consumed,
    b.credits_billed_cloud_services,

    -- simple anomaly flag
    IFF(
      trailing_stddev IS NOT NULL
      AND trailing_stddev > 0
      AND (w.credits_used_total_wh - trailing_mean) / trailing_stddev >= 3,
      TRUE, FALSE
    )                                                         AS is_spike_3sigma,

    -- link to events (optional join in downstream model)
    -- warehouse events have latency up to ~3h, so treat as best-effort explanations
    trailing_mean,
    trailing_stddev
FROM wh_daily w
JOIN daily_billed b
  ON b.usage_date = w.usage_date
LEFT JOIN wh_baseline bl
  ON bl.usage_date = w.usage_date
 AND bl.warehouse_name = w.warehouse_name
ORDER BY 1 DESC, 2;
```

Notes / extensions:
- Add a join to `WAREHOUSE_EVENTS_HISTORY` on `(warehouse_name, TO_DATE(timestamp)=usage_date)` to annotate “resized” / “autosuspend” days as possible causes for step changes. [4]
- If you want to estimate “billed credits in currency”, add a join to `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` (org context) and allocate by share of credits. [1]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Treating `WAREHOUSE_METERING_HISTORY` daily rollup as “billed warehouse cost” may diverge from invoice logic (e.g., cloud services adjustment is computed at account daily level). | Misleading “billed” vs “consumed” comparisons at warehouse granularity. | Reconcile totals by day against `METERING_DAILY_HISTORY` and Snowsight consumption dashboards. [1] |
| Event-to-cost attribution depends on `WAREHOUSE_EVENTS_HISTORY` timeliness and completeness (latency up to ~3h). | Root-cause explanations may lag or miss near-real-time spikes. | Confirm via doc latency note and validate against known changes (e.g., manual resize). [4] |
| Simple z-score anomaly detection assumes stable variance and ignores seasonality (weekday patterns). | False positives/negatives. | Add seasonality-aware baselines (DoW/hour) once the daily ledger exists. |

## Links & Citations

1. Exploring compute cost (views, cloud services billing rule, metering_daily_history, currency view): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. Managing cost in Snowflake (visibility/control/optimization framework): https://docs.snowflake.com/en/user-guide/cost-management-overview
3. Monitoring warehouse load (query load definition and interpretation for inefficiency): https://docs.snowflake.com/en/user-guide/warehouses-load-monitoring
4. WAREHOUSE_EVENTS_HISTORY view (event types, cost impact notes, latency up to ~3h): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_events_history

## Next Steps / Follow-ups

- Add a second research note under `native-apps/` on how to expose the above ledger + anomalies inside a Native App (privileges, packaging, data sharing constraints).
- Expand the artifact into a canonical “FinOps ledger schema” (dim_date, dim_warehouse, fact_warehouse_daily, fact_account_daily) that the Native App can materialize.
- Add a “spike explainer” query that surfaces top contributors: warehouse resize events, top query types by `credits_used_cloud_services`, and changes in queue/load metrics.
