# Research: FinOps - 2026-03-01

**Time:** 2130 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for the last 365 days, including split-out `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and an attribution metric `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` that **excludes idle time**. The `CREDITS_USED` value is **not “billed credits”** because it does not include the daily cloud-services adjustment. (So `CREDITS_USED` can be higher than what is billed.)
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** usage with `CREDITS_BILLED` and includes the cloud-services adjustment (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`, negative). Snowflake recommends this view to determine **how many credits were actually billed** (vs. just consumed).
3. `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` provides the same daily billing-oriented fields at the **organization + account** granularity (1 year retention, ~120 min latency).
4. To reconcile Account Usage views to Organization Usage views, Snowflake notes you must set session timezone to UTC before querying the Account Usage views.
5. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `QUERY_TAG`, `ROLE_NAME`, `USER_NAME`, and warehouse identifiers for each query, enabling FinOps attribution dimensions (team, app, workload) when query tagging is used consistently.
6. Resource Monitors help control costs for **warehouses only**; they **cannot track** serverless features and AI services. Snowflake suggests using **budgets** to monitor those.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly credits used per warehouse; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query exec only) and compute vs cloud services split. Latency up to 180 min; cloud services column up to 6h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | `ACCOUNT_USAGE` | Daily `CREDITS_BILLED` + cloud services adjustment. Suggested for billed credits. Latency up to 180 min. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | view | `ORG_USAGE` | Daily org-level view with per-account breakdown, includes `CREDITS_BILLED`. Latency up to 120 min. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | `ACCOUNT_USAGE` | Query metadata incl. `QUERY_TAG`, warehouse, role, user, timings, etc. Enables attribution when tags are present. |
| Resource Monitor objects | object | n/a (DDL objects) | Track/limit credit usage for warehouses; not for serverless/AI services. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost detector per warehouse**: daily and hourly idle cost = `credits_used_compute - credits_attributed_compute_queries`; rank by worst offenders; link to query history for likely culprits (long gaps, bursty schedules).
2. **Billed-credit allocator (daily)**: allocate `METERING_DAILY_HISTORY.CREDITS_BILLED` (SERVICE_TYPE = `WAREHOUSE_METERING`) down to warehouses using `WAREHOUSE_METERING_HISTORY.CREDITS_USED` as weights; expose confidence score + reconciliation delta.
3. **Query tagging compliance dashboard**: % of credits attributed to queries with non-null `QUERY_TAG` by warehouse/role; drive enforceable policy (“no tag, no prod”).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: allocate daily billed warehouse credits down to warehouses + compute idle cost

Goal: produce a *warehouse-day* table with (a) used credits, (b) idle-cost estimate, and (c) an allocation of **billed** credits using daily billing totals.

```sql
-- Warehouse-day rollup + billed-credit allocation.
-- Notes:
-- - METERING_DAILY_HISTORY is the billing-oriented source (includes cloud services adjustment).
-- - WAREHOUSE_METERING_HISTORY is hourly usage; we roll up to day.
-- - This allocates daily billed credits for SERVICE_TYPE='WAREHOUSE_METERING'
--   to warehouses proportional to their daily used credits.
--
-- Assumptions:
-- - SERVICE_TYPE='WAREHOUSE_METERING' exists in ACCOUNT_USAGE.METERING_DAILY_HISTORY.
-- - Allocation is approximate; billed credits include adjustments not directly attributable per warehouse.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used) AS credits_used,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
wh_daily AS (
  SELECT
    usage_date,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute
  FROM wh_hourly
),
wh_daily_totals AS (
  SELECT
    usage_date,
    SUM(credits_used) AS credits_used_all_wh
  FROM wh_daily
  GROUP BY 1
),
acct_billing AS (
  SELECT
    usage_date,
    -- Billing-oriented daily credits.
    SUM(credits_billed) AS credits_billed_warehouse_metering
  FROM snowflake.account_usage.metering_daily_history
  WHERE service_type = 'WAREHOUSE_METERING'
    AND usage_date >= DATEADD('DAY', -30, CURRENT_DATE())
  GROUP BY 1
)
SELECT
  d.usage_date,
  d.warehouse_name,
  d.credits_used,
  d.credits_used_compute,
  d.credits_used_cloud_services,
  d.credits_attributed_compute_queries,
  d.credits_idle_compute,
  b.credits_billed_warehouse_metering,
  t.credits_used_all_wh,
  IFF(t.credits_used_all_wh = 0, NULL,
      b.credits_billed_warehouse_metering * (d.credits_used / t.credits_used_all_wh)
  ) AS credits_billed_allocated_to_wh,
  -- Optional: explainability metric
  IFF(t.credits_used_all_wh = 0, NULL,
      d.credits_used / t.credits_used_all_wh
  ) AS wh_share_of_used
FROM wh_daily d
JOIN wh_daily_totals t
  ON t.usage_date = d.usage_date
LEFT JOIN acct_billing b
  ON b.usage_date = d.usage_date
ORDER BY 1 DESC, credits_billed_allocated_to_wh DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Billing totals cannot be perfectly attributed to warehouses | Allocated billed credits are **approximate**, especially around cloud services adjustments, rebates, and non-warehouse services | Compare (1) sum allocated warehouse billed credits vs (2) daily billed totals for `SERVICE_TYPE='WAREHOUSE_METERING'`; track delta over time |
| Timezone mismatch between views | Off-by-one-day joins or reconciliation failures | Always `ALTER SESSION SET TIMEZONE = 'UTC'` before querying Account Usage when reconciling with Organization Usage |
| Query tagging is inconsistent | Attribution by team/app is low-quality | Measure tag coverage in `ACCOUNT_USAGE.QUERY_HISTORY` (null/blank tags, tag taxonomy drift) |
| Resource monitors do not cover serverless/AI spend | Blind spots for fast-growing spend categories | Use `METERING_DAILY_HISTORY` by `SERVICE_TYPE` + budgets for serverless/AI services |

## Links & Citations

1. `WAREHOUSE_METERING_HISTORY` view (hourly warehouse credits; notes on billed vs used, latency, idle time example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. `METERING_DAILY_HISTORY` view in `ACCOUNT_USAGE` (daily billed credits + cloud services adjustment; UTC reconciliation note): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. `METERING_DAILY_HISTORY` view in `ORGANIZATION_USAGE` (daily billed credits at org+account level; service types list; latency): https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
4. `QUERY_HISTORY` view (includes `QUERY_TAG` plus many attribution dimensions): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
5. Resource Monitors (warehouse-only; serverless/AI requires budgets): https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Add a companion query that computes **tag coverage** (credits by tag vs untagged) per warehouse/day, using `ACCOUNT_USAGE.QUERY_HISTORY`.
- Pull `ORGANIZATION_USAGE.METERING_DAILY_HISTORY` for multi-account org rollups; validate reconciliation approach using UTC session timezone.
- Design a native-app-friendly ingestion strategy for these views (what’s accessible to an installed app vs requires customer-provided grants/streams).