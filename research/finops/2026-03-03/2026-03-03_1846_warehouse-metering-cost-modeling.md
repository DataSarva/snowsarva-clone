# Research: FinOps - 2026-03-03

**Time:** 18:46 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, and includes `CREDITS_USED = CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES`. It also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which **excludes warehouse idle time**.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. The `CREDITS_USED` numbers in `WAREHOUSE_METERING_HISTORY` **do not apply the daily cloud services 10% billing adjustment**, so `CREDITS_USED` may be **greater than billed** credits. Snowflake explicitly recommends using `METERING_DAILY_HISTORY` to determine credits that were actually billed (for reconciliation).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` is the **account-level** hourly credit usage view (last 365 days) and includes a `SERVICE_TYPE` dimension with many categories (e.g., `WAREHOUSE_METERING`, `QUERY_ACCELERATION`, `SEARCH_OPTIMIZATION`, `SNOWPARK_CONTAINER_SERVICES`, `AI_SERVICES`, etc.).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. For warehouses, Snowflake billing is **per-second with a 60-second minimum** each time a warehouse is started/resumed. Suspending/resuming within the first minute can result in **multiple 1-minute minimum charges**.  
   Source: https://docs.snowflake.com/en/user-guide/cost-understanding-compute
5. Cloud services billing is charged only if **daily cloud services consumption exceeds 10%** of daily warehouse usage; the adjustment is calculated **daily in UTC**. Serverless compute does **not** factor into the 10% adjustment.  
   Source: https://docs.snowflake.com/en/user-guide/cost-understanding-compute
6. Resource monitors can help control costs by tracking warehouse + supporting cloud services credit usage and can suspend user-managed warehouses when a quota threshold is reached, but:
   - resource monitors work for **warehouses only** (not serverless features / AI services); to monitor those, use a **budget**.
   - resource monitor limits **do not account for** the daily 10% cloud services billing adjustment (they use “raw” consumption).  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` excludes idle; `CREDITS_USED` is raw consumption and may exceed billed due to cloud services adjustment; up to 3h latency (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account credits by `SERVICE_TYPE` and entity identifiers. Useful for separating warehouse vs serverless vs “other” costs. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned as the recommended view to determine **billed** credits (vs raw consumption) for reconciliation. **Not extracted today**; treat as follow-up to confirm columns/behavior. |
| Resource Monitors (`CREATE RESOURCE MONITOR`, `SHOW RESOURCE MONITORS`) | Object + DDL | N/A | A first-class object for quota/threshold controls on warehouses; resets at 00:00 UTC for custom schedules. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse “Idle Cost” view**: For each warehouse/day (or hour), compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` and rank warehouses by idle %. This is directly supported by `WAREHOUSE_METERING_HISTORY`. (Surface as “Idle burn” in app UI.)  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. **Billed-vs-consumed reconciliation module**: Show “raw consumed credits” (from `WAREHOUSE_METERING_HISTORY`) vs “billed credits” (from `METERING_DAILY_HISTORY`) and explicitly annotate that cloud services billing uses the **10% daily adjustment in UTC**. This would reduce confusion and support finance reconciliation.
   Sources: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history , https://docs.snowflake.com/en/user-guide/cost-understanding-compute
3. **Resource Monitor lint + recommendations**: Detect warehouses that are frequently resumed/suspended (from query patterns + start/stop metadata in other views) and recommend avoiding resume/suspend thrash because of the **60-second minimum** billing. Also lint monitor thresholds to include buffer (e.g., 90% suspend).  
   Sources: https://docs.snowflake.com/en/user-guide/cost-understanding-compute , https://docs.snowflake.com/en/user-guide/resource-monitors

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Hourly + Daily Warehouse Idle Credits (raw consumption)

```sql
-- Purpose:
--   Compute hourly idle credits per warehouse and roll up daily.
-- Why it matters:
--   WAREHOUSE_METERING_HISTORY provides both total compute credits and compute credits attributed
--   to queries; the delta approximates idle/baseline burn (warehouses running but not executing queries).
-- Source:
--   https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

-- NOTE: If you later reconcile with ORG_USAGE or billing rollups, align to UTC where required.
-- The WAREHOUSE_METERING_HISTORY doc explicitly notes setting TIMEZONE=UTC for reconciliation.
ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time)          AS hour_start_utc,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS idle_credits_compute,
    credits_used_cloud_services,
    credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
  TO_DATE(hour_start_utc) AS usage_date_utc,
  warehouse_name,
  SUM(credits_used_compute)                 AS compute_credits,
  SUM(credits_attributed_compute_queries)   AS attributed_query_credits,
  SUM(idle_credits_compute)                 AS idle_compute_credits,
  IFF(SUM(credits_used_compute) = 0, NULL,
      SUM(idle_credits_compute) / SUM(credits_used_compute)) AS idle_pct_of_compute,
  SUM(credits_used_cloud_services)          AS cloud_services_credits_raw,
  SUM(credits_used)                         AS total_credits_raw
FROM hourly
GROUP BY 1, 2
ORDER BY usage_date_utc DESC, total_credits_raw DESC;
```

### ADR Stub: “Consumed vs Billed Credits” as a first-class concept in the app

```text
Context
- Multiple Snowflake views report credit usage.
- WAREHOUSE_METERING_HISTORY reports raw warehouse credits and explicitly notes that CREDITS_USED does not
  account for cloud services adjustment; billed credits require METERING_DAILY_HISTORY.

Decision
- The app will display two distinct measures:
  (1) Consumed credits (raw) from warehouse / service metering views.
  (2) Billed credits from the billing-aligned daily view (METERING_DAILY_HISTORY) once integrated.

Consequences
- UI must clearly label the difference and provide reconciliation guidance.
- Any “percentage of bill” analytics must use billed credits, not raw consumption.

Open Questions
- Confirm exact columns and grain of METERING_DAILY_HISTORY via extraction + example queries.
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `credits_used_compute - credits_attributed_compute_queries` is a sufficient proxy for “idle cost” | Might mislead if attribution semantics change or if some compute is not attributable but not “idle” | Validate on a known workload; cross-check with warehouse state / query history-derived activity windows. |
| We haven’t extracted `METERING_DAILY_HISTORY` today (only referenced by docs) | Reconciliation feature depends on exact columns and join keys | Run Parallel extract on `METERING_DAILY_HISTORY` docs and build sample queries in next session. |
| 60-second minimum billing creates “resume thrash” cost, but we’re not yet correlating resumes with billing events | Recommendations might be generic without evidence | Pull warehouse start/stop/resume timestamps from warehouse usage/metadata views and correlate with billing spikes. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/user-guide/cost-understanding-compute
4. https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Extract + validate `METERING_DAILY_HISTORY` docs (columns + examples) and add a “billed credits” SQL rollup.
- Add ORG_USAGE reconciliation notes: `WAREHOUSE_METERING_HISTORY` mentions setting session timezone to UTC before reconciling to ORG_USAGE.
- Design a minimal schema for storing computed daily warehouse KPIs (idle %, resume thrash flags, raw vs billed deltas) for the Native App UI.
