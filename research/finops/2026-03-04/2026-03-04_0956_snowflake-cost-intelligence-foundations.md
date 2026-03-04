# Research: FinOps - 2026-03-04

**Time:** 09:56 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit consumption per warehouse (including a compute vs cloud services breakdown), but the total `CREDITS_USED` in that view does **not** account for the daily cloud services billing adjustment; reconciling to **billed** credits requires `METERING_DAILY_HISTORY`. [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits used and **credits billed** (including `CREDITS_ADJUSTMENT_CLOUD_SERVICES`, which can be negative), and has ~up to 180 minutes of latency. [2]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `WAREHOUSE_NAME`, `USER_NAME`, `ROLE_NAME`, and `QUERY_TAG` for each statement, enabling attribution and policy patterns (e.g., “all scheduled pipelines must set QUERY_TAG”). [3]
4. Snowflake **resource monitors** can help control costs by tracking and enforcing credit quotas for **warehouses** (including actions like notify/suspend), but **resource monitors do not cover serverless + AI services**; Snowflake recommends using **budgets** to monitor credit consumption by those features. [4]
5. The `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` view exposes key monitor configuration and state including `CREDIT_QUOTA`, `USED_CREDITS`, `REMAINING_CREDITS`, thresholds (`NOTIFY`, `SUSPEND`, `SUSPEND_IMMEDIATE`), and `LEVEL` (account vs warehouse). [5]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly usage by warehouse; includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to ~180 min; cloud services column up to ~6h. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits; includes `CREDITS_BILLED` and `CREDITS_ADJUSTMENT_CLOUD_SERVICES` for billed-vs-consumed reconciliation. Latency up to ~180 min. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Statement-level metadata including `QUERY_TAG`, `WAREHOUSE_NAME`, `USER_NAME`, and timing/bytes metrics; can be used for attribution + guardrails. [3] |
| Resource monitor object | Object | N/A (object) | First-class object with quota, schedule, and actions (notify/suspend). Warehouses-only; not serverless/AI services. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | ACCOUNT_USAGE | Monitor inventory + thresholds + used credits. [5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost scorecard per warehouse**: compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` daily and alert on high idle ratio. (Uses `WAREHOUSE_METERING_HISTORY`.) [1]
2. **Billed vs consumed reconciliation widget**: show daily `CREDITS_USED_*` vs `CREDITS_BILLED` and attribute deltas to cloud services adjustment. (Uses `METERING_DAILY_HISTORY`.) [2]
3. **Query tagging coverage + top spenders**: percent of queries missing `QUERY_TAG` by warehouse/user/role and a “top tagged workloads” breakdown for chargeback/showback. (Uses `QUERY_HISTORY`.) [3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: warehouse daily cost + idle ratio (compute-only)

```sql
/*
Goal:
- Daily warehouse cost (compute credits)
- Idle credits and idle ratio

Notes:
- WAREHOUSE_METERING_HISTORY is hourly; roll up by DATE(START_TIME).
- Idle credits: (compute credits) - (credits attributed to compute queries)
- This attribution excludes idle time by definition.

Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
*/

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('DAY', start_time)          AS usage_day,
    warehouse_name,
    SUM(credits_used_compute)             AS credits_compute,
    SUM(credits_used_cloud_services)      AS credits_cloud_services,
    SUM(credits_attributed_compute_queries) AS credits_attrib_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
)
SELECT
  usage_day,
  warehouse_name,
  credits_compute,
  credits_attrib_queries,
  GREATEST(credits_compute - credits_attrib_queries, 0) AS credits_idle,
  IFF(credits_compute = 0, NULL,
      (GREATEST(credits_compute - credits_attrib_queries, 0) / credits_compute)
  ) AS idle_ratio,
  credits_cloud_services
FROM hourly
ORDER BY usage_day DESC, credits_compute DESC;
```

### SQL draft: daily billed credits for the full account (reconciliation anchor)

```sql
/*
Goal:
- Track billed credits at the daily grain (account-level)
- Use this as the reconciliation anchor vs rollups from other views

Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
*/

ALTER SESSION SET TIMEZONE = 'UTC';

SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY usage_date DESC, credits_billed DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` latency (hours) means dashboards/alerts can be delayed. | “Near real-time” alerts may miss spikes until later. | Confirm observed lag in target accounts; consider complementing with `INFORMATION_SCHEMA` (where applicable) or event-driven tagging/controls. [1][2] |
| Billed credits (`METERING_DAILY_HISTORY`) are account/service-type level; warehouse-level hourly rollups won’t sum to billed credits exactly due to adjustments + non-warehouse service types. | Reconciliation gaps could confuse users. | Present reconciliation as “expected delta” and explain adjustment mechanics; ensure UX labels this clearly. [1][2] |
| Resource monitors only apply to warehouses, not serverless/AI services. | If the app relies on resource monitors for “budgeting,” it will miss serverless spend. | Implement separate “budgets” integration path for serverless/AI monitoring as Snowflake recommends. [4] |
| Query attribution by `QUERY_TAG` depends on users/pipelines actually setting it. | Chargeback/showback will be incomplete. | Add coverage reporting + suggested enforcement pattern (session policies / conventions / wrappers). [3] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/user-guide/resource-monitors
5. https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors

## Next Steps / Follow-ups

- Pull Snowflake docs for **Budgets** (and the underlying usage views) to formalize the serverless/AI spend path (resource monitors won’t cover it). [4]
- Define an MVP “Cost Attribution Contract” for the Native App (minimum: warehouse → query_tag → owner mapping) and decide which parts are advisory vs enforceable.
- Add an app-level reconciliation model: daily billed credits (account) vs attributed credits (warehouses + serverless categories) with explicit deltas.
