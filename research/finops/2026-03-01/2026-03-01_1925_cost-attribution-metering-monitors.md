# Research: FinOps - 2026-03-01

**Time:** 19:25 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** warehouse credit usage for up to **365 days**, and includes columns to separate compute vs cloud-services credits, plus a column that attributes compute credits to queries (excluding idle). (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. Warehouse idle time (credits spent while the warehouse is running but not executing queries) can be computed as: `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` over a window; Snowflake provides this exact pattern as an example. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage and also includes fields that represent the **cloud services adjustment** (rebate) and a `CREDITS_BILLED` field (used + adjustment). (https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history)
4. The **daily** 10% cloud-services adjustment affects billing; `WAREHOUSE_METERING_HISTORY.CREDITS_USED` does **not** account for that adjustment and may exceed credits actually billed. Snowflake documentation directs users to `METERING_DAILY_HISTORY` to determine billed credits. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) (https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history)
5. Resource monitors can **monitor warehouses (and their supporting cloud services)** and take actions (notify/suspend), but they **work for warehouses only**; they do **not** track serverless features or AI services, and Snowflake says to use a **budget** to monitor those instead. (https://docs.snowflake.com/en/user-guide/resource-monitors)
6. `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` returns hourly warehouse credit usage **across all accounts in an org** (365 days retention mentioned) and can be used for cross-account rollups; its data latency may be up to 24 hours. (https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly usage per warehouse; includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 3h (cloud services column up to 6h). (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily usage + cloud services adjustment + billed credits. Use for “what was billed” questions. Latency up to 3h. (https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history) |
| Resource monitor object (`CREATE/ALTER/SHOW RESOURCE MONITORS`) | Object | N/A (object) | Resource monitors act on warehouses; not serverless/AI. Reset schedule is monthly by default; custom resets at 12:00 AM UTC. (https://docs.snowflake.com/en/user-guide/resource-monitors) |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Org-level hourly warehouse usage across accounts; latency up to 24h. (https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost leaderboard per warehouse**: daily/weekly rollup of `idle_cost = credits_used_compute - credits_attributed_compute_queries`, with “top regressions vs trailing 7-day baseline” for fast FinOps triage.
2. **Billed vs used reconciliation panel**: show `METERING_DAILY_HISTORY.CREDITS_USED` vs `CREDITS_BILLED`, and quantify cloud-services adjustment; annotate that hourly warehouse totals do not include the adjustment.
3. **Resource monitor coverage gaps**: flag credit consumers that cannot be controlled by resource monitors (serverless + AI services) by comparing `METERING_DAILY_HISTORY.SERVICE_TYPE` values vs “warehouse-only” controls.

## Concrete Artifacts

### SQL draft: Daily warehouse idle-cost + (approx) billed-credit allocation

Goal: produce a daily warehouse-level table that (a) quantifies idle compute cost and (b) allocates account-level billed credits to warehouses in a defensible way.

Important: Snowflake’s cloud-services billing adjustment is computed at the **account/day** level (per docs). There is no doc-guaranteed “true billed credits per warehouse per hour” view. The allocation below is therefore an **inference** and must be labeled as such in-product.

```sql
-- Daily warehouse idle-cost and estimated billed credits allocation
-- Sources:
--  - ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly warehouse usage)
--  - ACCOUNT_USAGE.METERING_DAILY_HISTORY (daily billed credits)
--
-- Notes:
--  - WAREHOUSE_METERING_HISTORY.CREDITS_USED does NOT incorporate the daily cloud-services adjustment;
--    billed credits must come from METERING_DAILY_HISTORY. (docs)
--  - Allocation strategy: allocate billed credits to warehouses proportional to their daily (compute + cloud services) used credits.
--    This is a heuristic.

WITH wh_daily AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1,2
),
acct_billed AS (
  SELECT
    usage_date,
    SUM(credits_billed) AS acct_credits_billed,
    SUM(credits_used) AS acct_credits_used,
    SUM(credits_adjustment_cloud_services) AS acct_cloud_services_adjustment
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1
),
wh_daily_with_totals AS (
  SELECT
    w.*,
    (w.credits_used_compute + w.credits_used_cloud_services) AS wh_credits_used_total,
    SUM(w.credits_used_compute + w.credits_used_cloud_services)
      OVER (PARTITION BY w.usage_date) AS acct_wh_credits_used_total
  FROM wh_daily w
)
SELECT
  w.usage_date,
  w.warehouse_name,
  w.credits_used_compute,
  w.credits_used_cloud_services,
  w.idle_compute_credits,
  a.acct_cloud_services_adjustment,

  /* Heuristic allocation of billed credits */
  IFF(w.acct_wh_credits_used_total = 0, NULL,
      a.acct_credits_billed * (w.wh_credits_used_total / w.acct_wh_credits_used_total)
  ) AS est_billed_credits_allocated
FROM wh_daily_with_totals w
JOIN acct_billed a
  ON a.usage_date = w.usage_date
ORDER BY 1 DESC, est_billed_credits_allocated DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| **Assumption:** billed credits cannot be precisely attributed to individual warehouses from `METERING_DAILY_HISTORY` without an allocation heuristic. | Misleading “true cost by warehouse” if presented as authoritative. | Keep UI labeling explicit (“estimated allocation”) and provide reconciliation to account-level totals. Compare with known billing totals. |
| Data latency (ACCOUNT_USAGE up to 3h; some columns up to 6h; ORG usage up to 24h) can cause “incomplete day” charts. | Dashboard may show apparent drops/spikes. | Implement freshness watermarking; delay finalization until expected latency window passes. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) (https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history) |
| Resource monitors don’t control serverless/AI spend. | Customers may think they have spend controls but still see overages. | In product, enumerate `METERING_DAILY_HISTORY.SERVICE_TYPE` non-warehouse items and recommend budgets. (https://docs.snowflake.com/en/user-guide/resource-monitors) |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY (Account Usage view): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. METERING_DAILY_HISTORY (Account Usage view): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Working with resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
4. WAREHOUSE_METERING_HISTORY (Organization Usage view): https://docs.snowflake.com/en/sql-reference/organization-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Add a second research pass on **budgets** (since Snowflake positions budgets as the control plane for serverless + AI services) and map how budgets show up in system views (if any).
- Identify the best “cost by team/project” attribution approach (tags? query attribution?) and what views expose tag lineage and/or query tags.
