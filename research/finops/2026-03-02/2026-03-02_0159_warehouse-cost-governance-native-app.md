# Research: FinOps - 2026-03-02

**Time:** 01:59 UTC  
**Topic:** Snowflake FinOps Cost Optimization (warehouse credit usage, idle cost, cloud services billing nuances, tag-based attribution)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for the last **365 days**, including compute credits and cloud services credits, and includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which **excludes idle time**. (Account Usage view) [1]
2. The `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` **table function** is limited to the last **6 months**, and Snowflake explicitly recommends using the **ACCOUNT_USAGE** view for a complete dataset when querying multiple warehouses or a lengthy time range. [2]
3. Account Usage views can have non-trivial latency: `WAREHOUSE_METERING_HISTORY` latency is up to **180 minutes**, except `CREDITS_USED_CLOUD_SERVICES` which can lag up to **6 hours**. [1]
4. To reconcile `ACCOUNT_USAGE` with corresponding `ORGANIZATION_USAGE` views, Snowflake instructs setting the session timezone to **UTC** before querying the Account Usage view. [1]
5. Warehouse compute is billed **per-second** with a **60-second minimum** each time a warehouse starts/resumes, and also when resizing upward (billing for an additional-minute minimum for the additional compute). This creates measurable “cold start / resize tax” patterns in cost data. [3]
6. Cloud services credits are **not always billed**: usage for cloud services is charged only if **daily** cloud services consumption exceeds **10%** of daily virtual warehouse usage; the “adjustment” is computed daily in **UTC**. Many dashboards/views show credits consumed without accounting for this daily adjustment; `METERING_DAILY_HISTORY` can be used to determine credits actually billed. [3][4]
7. Snowsight cost management supports filtering consumption by **tag**; tags can be applied to resources so costs can be attributed to logical units (cost center/env/etc.). This provides a first-party cost allocation mechanism the Native App can audit/operationalize. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits for 365 days; includes `CREDITS_USED_*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. Latency up to 3h (cloud services up to 6h). UTC timezone recommended for reconciliation. [1] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | Hourly warehouse credits for last 6 months; requires `MONITOR USAGE` (or ACCOUNTADMIN) and `INFORMATION_SCHEMA` in use or fully qualified. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to determine billed cloud services via `credits_used_cloud_services + credits_adjustment_cloud_services`. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly, account-wide credits by service type; can be filtered by `SERVICE_TYPE`. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse Idle Cost Lens (per warehouse, per day, trend + top offenders):** compute `idle_cost = credits_used_compute - credits_attributed_compute_queries` (hourly or daily rollups). Provide alerting for warehouses with sustained high idle ratio. Source-of-truth is `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`. [1]
2. **Cloud Services “Billed vs Consumed” Explainer & Report:** surface daily cloud services consumed vs billed adjustment using `ACCOUNT_USAGE.METERING_DAILY_HISTORY`, and clearly label that many other views show “consumed” not “billed.” [3][4]
3. **Tag Coverage & Cost Allocation Audit:** inventory which warehouses are tagged for cost center/env attribution (since Snowsight supports tag-based filtering), flag untagged resources, and provide rollout guidance for tagging strategy. [4]

## Concrete Artifacts

### SQL draft: Warehouse idle cost + cloud services ratio + anomaly candidates

```sql
/*
Purpose
  Produce a FinOps-ready daily rollup per warehouse:
  - total credits (compute + cloud services)
  - idle credits estimate (compute credits not attributed to queries)
  - cloud services % of total credits
  - last-data freshness hints (implicit via MAX(start_time))

Notes (from docs)
  - ACCOUNT_USAGE latency can be up to 180 minutes; cloud services up to 6 hours. [1]
  - Pseudo warehouses exist (e.g., CLOUD_SERVICES_ONLY); docs often filter with warehouse_id > 0. [4]
*/

WITH hourly AS (
  SELECT
    start_time,
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_id > 0
),
daily AS (
  SELECT
    usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used) AS credits_used_total,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    /* idle time not included in credits_attributed_compute_queries [1] */
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS credits_idle_compute_est,
    IFF(SUM(credits_used) = 0, NULL,
        SUM(credits_used_cloud_services) / SUM(credits_used)) AS cloud_services_pct
  FROM hourly
  GROUP BY 1,2,3
)
SELECT
  usage_date,
  warehouse_name,
  credits_used_total,
  credits_used_compute,
  credits_used_cloud_services,
  credits_idle_compute_est,
  cloud_services_pct
FROM daily
QUALIFY credits_used_total > 0
ORDER BY usage_date DESC, credits_used_total DESC;
```

### SQL draft: Daily billed cloud services (account-level)

```sql
/*
Docs note: cloud services credits are billed only if daily cloud services consumption
exceeds 10% of daily warehouse usage; many views show consumed credits without the adjustment. [3][4]
*/
SELECT
  usage_date,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_used_cloud_services + credits_adjustment_cloud_services AS billed_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('month', -1, CURRENT_DATE())
  AND credits_used_cloud_services > 0
ORDER BY billed_cloud_services DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| **Idle cost** computed as `credits_used_compute - credits_attributed_compute_queries` is a useful proxy, but may not fully represent “waste” (e.g., intentional warm warehouses, multi-cluster behavior, short-lived spikes). | False positives in alerts; may annoy platform teams. | Validate against a few real warehouses; compare with known schedules / ETL windows; tune thresholds and allow “expected idle” windows. |
| Cloud services credits in `WAREHOUSE_METERING_HISTORY` may lag up to 6 hours. | Near-real-time dashboards may show temporarily low cloud services % and later “jump.” | Add “data freshness” UI and delay-sensitive alerting; use a trailing window excluding last N hours. [1] |
| Cross-account/org rollups require `ORGANIZATION_USAGE` and UTC reconciliation. | Inaccurate cross-account comparisons if timezone not handled. | Enforce `ALTER SESSION SET TIMEZONE = UTC` in analysis jobs / stored procedures. [1] |
| Tag-based allocation depends on adoption/discipline; many orgs are partially tagged. | Coverage gaps reduce value of cost attribution features. | Build “tag coverage score” and rollout playbook; show quick wins (top spend untagged). [4] |

## Links & Citations

1. Snowflake Docs: `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view (columns, latency, idle time note, UTC reconciliation) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Docs: `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` table function (6-month limit; MONITOR USAGE requirement) — https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
3. Snowflake Docs: Understanding compute cost (per-second billing + 60-second minimum; 10% cloud services adjustment description) — https://docs.snowflake.com/en/user-guide/cost-understanding-compute
4. Snowflake Docs: Exploring compute cost (tag filtering in Snowsight; billed cloud services query via `METERING_DAILY_HISTORY`; example queries) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Add a **native-app data contract** for “warehouse daily rollup” + “billed cloud services daily” tables in the app schema; use them as stable inputs for dashboards/alerts.
- Implement an alert heuristic that ignores the most recent **6 hours** for cloud services ratios due to known latency. [1]
- Decide whether the first release targets **account-level** only (`ACCOUNT_USAGE`) vs optional **org-level** (`ORGANIZATION_USAGE`) rollups; if org-level, bake UTC and privilege requirements into setup checks. [1]
