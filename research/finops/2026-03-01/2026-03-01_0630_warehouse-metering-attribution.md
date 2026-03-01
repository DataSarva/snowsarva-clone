# Research: FinOps - 2026-03-01

**Time:** 0630 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including separate columns for `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`. It also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which **excludes warehouse idle time**. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. For `WAREHOUSE_METERING_HISTORY`, `CREDITS_USED` is the sum of compute + cloud services credits and **does not include the cloud services “billing adjustment”**; to determine actually billed compute credits (esp. the cloud services adjustment), Snowflake directs you to `METERING_DAILY_HISTORY`. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute , https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
3. Reconciling `ACCOUNT_USAGE` cost views against corresponding `ORGANIZATION_USAGE` views requires setting the session timezone to UTC (e.g., `ALTER SESSION SET TIMEZONE = UTC;`) prior to querying. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` returns **hourly** credit usage at an account level (not per-warehouse) and includes a `SERVICE_TYPE` dimension that can be used to break down costs across warehouses, serverless features, cloud services, and other services. (https://docs.snowflake.com/en/sql-reference/account-usage/metering_history)
5. Snowflake’s “Exploring compute cost” guide explicitly calls out that cloud services credits are **only billed if** daily cloud services consumption exceeds **10%** of daily virtual warehouse usage; many views (and Snowsight dashboards) show **consumed** credits without that daily adjustment. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute)
6. Third-party analysis of `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` suggests: data availability starting ~2024-07-01, exclusion of very short queries, idle time not included, and possible anomalies (e.g., warehouse id mismatches / inflated attribution) that warrant validation against metering. Treat it as useful but not automatically “ground truth.” (https://blog.greybeam.ai/snowflake-cost-per-query/)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credit usage; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed compute credits, excludes idle). Latency up to ~3h (cloud services column up to ~6h). (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credit usage for the account with `SERVICE_TYPE` breakdown across many services; doesn’t apply cloud services billing adjustment. (https://docs.snowflake.com/en/sql-reference/account-usage/metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Recommended by Snowflake to calculate *billed* credits, including cloud services adjustment. Mentioned in compute-cost guide. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Mentioned by Snowflake as feature-specific cost view for per-query warehouse usage; validate correctness and behavior in each account. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute , https://blog.greybeam.ai/snowflake-cost-per-query/) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse Idle Cost KPI + alerting:** compute (per day / per week) idle credits and idle ratio by warehouse using `CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES` from `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`. (Docs explicitly show this pattern.)
2. **"Consumed vs billed" compute reporting:** build a reconciliation view that shows consumed credits (from `WAREHOUSE_METERING_HISTORY` / `METERING_HISTORY`) versus billed credits (from `METERING_DAILY_HISTORY`), explicitly separating cloud services adjustment to prevent misleading dashboards.
3. **Query cost attribution “trust but verify” module:** support `QUERY_ATTRIBUTION_HISTORY` for per-query costs, but ship “validation checks” (e.g., compare hourly sums to metering; detect warehouse_id mismatches; surface % of warehouse credits covered by attribution) and degrade gracefully to time-weighted attribution if anomalies detected.

## Concrete Artifacts

### Artifact: Idle cost + idle ratio per warehouse (daily)

This is a minimal, repeatable computation for a FinOps dashboard.

```sql
-- Idle credits by warehouse per day
-- Source of truth for hourly warehouse credits: ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Docs: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

WITH hourly AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_day,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE warehouse_id > 0 -- exclude pseudo warehouses like CLOUD_SERVICES_ONLY
    AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
  usage_day,
  warehouse_name,
  SUM(credits_used_compute) AS credits_used_compute,
  SUM(credits_attributed_compute_queries) AS credits_attributed_to_queries,
  SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits,
  IFF(
    SUM(credits_used_compute) = 0,
    NULL,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / SUM(credits_used_compute)
  ) AS idle_ratio
FROM hourly
GROUP BY 1, 2
ORDER BY usage_day DESC, idle_credits DESC;
```

### Artifact: “Consumed vs billed” compute summary (organization policy-safe)

This is a sketch showing how we’d structure a daily dataset that’s explicit about billing adjustments.

```sql
-- Daily compute credits: consumed vs billed
-- Snowflake notes cloud services are billed only if daily cloud services exceeds 10% of daily warehouse usage.
-- Docs: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

SELECT
  usage_date,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used_compute + credits_used_cloud_services AS credits_consumed_total,
  credits_adjustment_cloud_services,
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS credits_billed_cloud_services,
  credits_used_compute + (credits_used_cloud_services + credits_adjustment_cloud_services) AS credits_billed_total
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY usage_date DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Many Snowflake cost views and dashboards show **consumed** credits without the cloud services billing adjustment. | FinOps UI could misstate “true bill” vs “consumption,” confusing stakeholders. | Always compute billed totals from `METERING_DAILY_HISTORY` alongside consumed totals; label them explicitly. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `ACCOUNT_USAGE` views have latency (hours). | Near-real-time dashboards/alerts may be stale or noisy. | For alerting, choose thresholds/time windows that tolerate latency; document expected lag (3–6h depending on column) for metering views. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| `QUERY_ATTRIBUTION_HISTORY` correctness / completeness can be account-dependent and may have anomalies. | Incorrect per-query cost attribution undermines trust. | Implement reconciliation checks against metering sums; surface coverage metrics; fall back to time-weighted approaches when anomalies detected. (https://blog.greybeam.ai/snowflake-cost-per-query/) |
| Reconciling Account Usage vs Organization Usage requires timezone normalization to UTC. | Off-by-one-hour/day issues in cross-account rollups. | Force `ALTER SESSION SET TIMEZONE = UTC;` in reconciliation jobs and document as requirement. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |

## Links & Citations

1. Snowflake docs: `WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE view) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake docs: Exploring compute cost (cloud services billing adjustment; cost views list incl. QUERY_ATTRIBUTION_HISTORY) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake docs: `METERING_HISTORY` (ACCOUNT_USAGE view) — https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Greybeam blog: Query cost + idle time attribution analysis; caveats on QUERY_ATTRIBUTION_HISTORY — https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Pull Snowflake authoritative docs for `QUERY_ATTRIBUTION_HISTORY` (columns, limits, retention) and add a first-party “contract” section to the app’s attribution module.
- Decide a canonical “cost truth hierarchy” for the app:
  - billed totals: `METERING_DAILY_HISTORY`
  - warehouse consumed totals: `WAREHOUSE_METERING_HISTORY`
  - per-query attribution: `QUERY_ATTRIBUTION_HISTORY` (with validation) or time-weighted fallback.
- Add a “UTC reconciliation” guardrail to any org-wide jobs that compare ORG_USAGE vs ACCOUNT_USAGE.
