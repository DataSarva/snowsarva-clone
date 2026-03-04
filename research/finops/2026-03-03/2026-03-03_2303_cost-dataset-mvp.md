# Research: FinOps - 2026-03-03

**Time:** 23:03 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse (or all warehouses) for the last **365 days**, including separate fields for compute vs cloud services, and a field for credits attributed to query execution (excluding idle). It has documented latency up to **180 minutes**, with **cloud services** credit columns up to **6 hours** latency. 
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is a sum of compute + cloud services credits and **does not** apply the “cloud services 10% daily adjustment”, so it can be **greater than billed** credits. To determine what was billed, Snowflake directs you to query `METERING_DAILY_HISTORY`.
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` exposes per-query operational metrics (elapsed time, bytes scanned, queueing times) and also includes a `CREDITS_USED_CLOUD_SERVICES` column (again, consumed not necessarily billed).
4. `SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY` provides **average daily** storage usage in bytes per database for the last **365 days**, including Time Travel bytes and Fail-safe bytes. The doc notes new storage lifecycle policy columns introduced via behavior change bundle **2025_07** (requires enabling the bundle).
5. Resource monitors are for **warehouses only** (user-managed virtual warehouses). They do **not** cover serverless features / AI services; the doc explicitly recommends using **budgets** for those.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits by warehouse; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to separate “query execution” from total compute, enabling idle estimation. Latency: up to 3h (cloud services up to 6h). |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Recommended by Snowflake to determine **billed** credits (applies cloud services adjustment). Mentioned in “Exploring compute cost”. |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits for warehouses + cloud services + serverless features (higher-level than per-warehouse). Mentioned in “Exploring compute cost”. |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY | View | ACCOUNT_USAGE | Per-query metrics + `CREDITS_USED_CLOUD_SERVICES` consumed. |
| SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY | View | ACCOUNT_USAGE | Daily average storage bytes per database; includes Time Travel + Fail-safe; mentions BCR bundle 2025_07 for new columns. |
| RESOURCE MONITOR (object) | Object | N/A | Cost control for warehouses only; can notify/suspend warehouses when thresholds reached; resets at 00:00 UTC. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse Idle Burn report (daily + hourly):** compute idle credits per warehouse using documented formula: `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` from `WAREHOUSE_METERING_HISTORY`, and trend it week-over-week.
2. **Consumed vs billed explainer + reconciliation panel:** show “consumed credits” (warehouse + serverless + cloud services) vs “billed credits” derived from `METERING_DAILY_HISTORY` with clear caveat that many views omit the cloud-services adjustment.
3. **Cost guardrails health check:** inventory resource monitors and verify coverage gaps: warehouses under monitors vs unmonitored; remind that serverless requires budgets (not resource monitors).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Daily warehouse efficiency (idle %, cloud services ratio, latency-aware)

```sql
/*
Goal: produce a compact daily mart per warehouse for the app.
Sources are doc-backed:
- WAREHOUSE_METERING_HISTORY provides total/compute/cloud-services + attributed-to-queries.
- METERING_DAILY_HISTORY should be used separately for billed-vs-consumed rollups.
*/

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_day,
    warehouse_name,
    SUM(credits_used)                    AS credits_used_total_consumed,
    SUM(credits_used_compute)            AS credits_used_compute_consumed,
    SUM(credits_used_cloud_services)     AS credits_used_cloud_services_consumed,
    SUM(credits_attributed_compute_queries) AS credits_attributed_to_queries_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND end_time   <  CURRENT_TIMESTAMP()
  GROUP BY 1,2
),
calc AS (
  SELECT
    usage_day,
    warehouse_name,
    credits_used_total_consumed,
    credits_used_compute_consumed,
    credits_used_cloud_services_consumed,
    credits_attributed_to_queries_compute,

    /* Doc example: idle = compute - attributed_to_queries (idle excludes cloud services). */
    GREATEST(credits_used_compute_consumed - credits_attributed_to_queries_compute, 0) AS credits_idle_compute,

    /* Ratios for ranking */
    IFF(credits_used_compute_consumed = 0, NULL,
        (credits_used_compute_consumed - credits_attributed_to_queries_compute) / credits_used_compute_consumed
    ) AS idle_pct_of_compute,

    IFF(credits_used_total_consumed = 0, NULL,
        credits_used_cloud_services_consumed / credits_used_total_consumed
    ) AS cloud_services_pct_of_total
  FROM wh
)
SELECT *
FROM calc
ORDER BY usage_day DESC, credits_idle_compute DESC;
```

### Artifact: ADR stub (consumed vs billed)

```text
ADR: Credit metrics in the FinOps Native App (Consumed vs Billed)

Context
- Several ACCOUNT_USAGE views report credits consumed by warehouses/cloud services/serverless.
- Snowflake docs warn some consumed values do not include the daily cloud-services billing adjustment.

Decision
- The app will store and display BOTH:
  1) CONSUMED credits (granular attribution + operational tuning)
  2) BILLED credits (true spend baseline) derived from METERING_DAILY_HISTORY

Consequences
- UI must label metrics clearly and avoid mixing them in charts.
- Alerts should be configurable: “operational waste” (consumed) vs “budget overspend” (billed).

Open questions
- Which services should be treated as “unattributable” and kept as overhead vs allocated?
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ACCOUNT_USAGE views have **latency** (up to 3h; cloud services up to 6h for WAREHOUSE_METERING_HISTORY columns). | Near-real-time dashboards will appear stale/incomplete. | Confirm by comparing recent hours vs later backfill; enforce a “data freshness” banner in UI. |
| “Consumed credits” != “billed credits” due to cloud services daily adjustment. | Users may distrust the app if spend doesn’t reconcile. | Use `METERING_DAILY_HISTORY` for billed rollups; present reconciliation view + doc link. |
| DATABASE_STORAGE_USAGE_HISTORY new lifecycle-policy columns require enabling bundle 2025_07. | Some columns may be missing depending on account behavior bundle state. | Detect column existence at runtime; degrade gracefully. |
| Resource monitors don’t cover serverless/AI services. | If we only build around monitors, we miss major spend categories. | Encourage/guide budgets for serverless categories; surface coverage gaps. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/database_storage_usage_history
4. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
5. https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Pull docs for `ACCOUNT_USAGE.METERING_DAILY_HISTORY` + `ACCOUNT_USAGE.METERING_HISTORY` and formalize the “billed vs consumed” reconciliation query.
- Add a “freshness watermark” spec: per-view latency windows and how UI should interpret the most recent N hours.
- Extend the mart with optional joins to `QUERY_ATTRIBUTION_HISTORY` (doc referenced in cost-attribution material) to split attributed compute by tag/cost center.
