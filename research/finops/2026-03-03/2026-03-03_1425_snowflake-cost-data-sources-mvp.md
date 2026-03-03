# Research: FinOps - 2026-03-03

**Time:** 14:25 UTC  
**Topic:** Snowflake FinOps Cost Optimization (metering + attribution primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` returns **hourly credit usage** for an account within the last **365 days**, with cost broken down by `SERVICE_TYPE` (e.g., `WAREHOUSE_METERING`, `SERVERLESS_TASK`, `SNOWPARK_CONTAINER_SERVICES`, etc.) and includes identifiers like `ENTITY_ID`, `ENTITY_TYPE`, and name fields that vary by service type. 
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly credit usage per warehouse** (or all warehouses) for the last **365 days**. It includes both `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`, and a derived field `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (execution only), enabling an **idle-cost estimate** via `credits_used_compute - credits_attributed_compute_queries`. The view has documented **latency up to ~3 hours** (and up to **6 hours** for cloud services usage fields). 
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` provides per-query metadata (e.g., `query_id`, `warehouse_name`, `role_name`, `user_name`, timestamps, elapsed times) and includes `query_tag`, enabling **governance- and cost-attribution hooks** (by tagging) even when the ultimate billed credits are accounted at warehouse/service level.
4. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` returns **daily** usage for an organization in both usage units (e.g., credits) and **currency**, and Snowflake recommends using `BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, and `IS_ADJUSTMENT` for billing reconciliation (rather than legacy `USAGE_TYPE`).
5. `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` exposes resource monitor definitions and current-cycle consumption fields (e.g., `CREDIT_QUOTA`, `USED_CREDITS`, `REMAINING_CREDITS`) plus thresholds (`NOTIFY`, `SUSPEND`, `SUSPEND_IMMEDIATE`) and warehouse assignments, which is sufficient to build “budget policy drift” checks and alerts.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly, 365d. Breaks down credits by `SERVICE_TYPE` + entity identifiers; good for top-level cost taxonomy. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly, 365d. Includes compute vs cloud services vs attributed-to-queries; supports idle-cost analysis; documented latency up to 180 min (3h) and up to 6h for cloud services. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level metadata with `query_tag` + warehouse/user/role; needed for attribution slices even if cost is estimated/allocated. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily org-level usage *and* currency; useful to reconcile to invoices and to show $-based KPIs. |
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | `ACCOUNT_USAGE` | Budget objects (quota/used/remaining + thresholds + warehouse assignments) for policy enforcement/guardrails. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost leaderboard (warehouse-level):** daily rollups of `(credits_used_compute - credits_attributed_compute_queries)` per warehouse, with a “top idle spenders” widget and a rule-based recommender (e.g., “enable auto-suspend”, “downsize”, “split ETL warehouse”). Source is purely `WAREHOUSE_METERING_HISTORY`.
2. **Tag-based allocation (lightweight):** allocate warehouse-hour compute credits to tags/users/roles by proportion of `execution_time` (or `total_elapsed_time`) from `QUERY_HISTORY` within each warehouse-hour bucket, producing approximate “cost by query_tag” without requiring external billing integration.
3. **Budget policy drift checks:** compare `RESOURCE_MONITORS` thresholds and `CREDIT_QUOTA` to configured policy (e.g., “all prod warehouses must be attached to a monitor with SUSPEND at 90%”) and surface violations.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily idle cost per warehouse (credits)

```sql
-- Daily idle-cost estimate per warehouse.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes: credits_attributed_compute_queries excludes idle-time usage.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
  DATE_TRUNC('day', hour_start) AS usage_day,
  warehouse_name,
  SUM(credits_used_compute) AS credits_compute,
  SUM(credits_attributed_compute_queries) AS credits_attributed,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS credits_idle_est
FROM hourly
GROUP BY 1, 2
ORDER BY usage_day DESC, credits_idle_est DESC;
```

### SQL Draft: Allocate warehouse-hour compute credits to query_tag (approx.)

```sql
-- Approximate allocation of warehouse-hour compute credits to query_tag.
-- Idea: within each warehouse + hour, distribute CREDITS_USED_COMPUTE
-- proportional to query execution_time. This yields an attribution model
-- (not a billed-truth model).

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    warehouse_name,
    credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
),
qh AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), 'UNSET') AS query_tag,
    SUM(execution_time) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    AND execution_status = 'SUCCESS'
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2, 3
),
den AS (
  SELECT hour_start, warehouse_name, SUM(exec_ms) AS total_exec_ms
  FROM qh
  GROUP BY 1, 2
)
SELECT
  qh.hour_start,
  qh.warehouse_name,
  qh.query_tag,
  wh.credits_used_compute,
  qh.exec_ms,
  den.total_exec_ms,
  IFF(den.total_exec_ms = 0, NULL, (qh.exec_ms / den.total_exec_ms) * wh.credits_used_compute) AS credits_allocated_est
FROM qh
JOIN den
  ON qh.hour_start = den.hour_start
 AND qh.warehouse_name = den.warehouse_name
JOIN wh
  ON qh.hour_start = wh.hour_start
 AND qh.warehouse_name = wh.warehouse_name
ORDER BY qh.hour_start DESC, credits_allocated_est DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocation model (credits → tags) is approximate and depends on `execution_time` being a reasonable proxy. | Users may treat estimates as billed truth; misallocation possible (esp. for concurrency/queued time). | Label outputs explicitly as estimates; compare totals to warehouse-hour credits; optionally test alternate proxies (elapsed time, bytes scanned). |
| ACCOUNT_USAGE view latency (hours) can make “near-real-time” alerts misleading. | Recent hours might look artificially low; alerts could trigger late. | Add freshness indicators; use lookback windows; avoid paging for data <6h old when relying on views with documented latency. |
| ORG_USAGE currency views might not be available/authorized in all accounts and may require org-level privileges. | App may fail or show incomplete data in some environments. | Detect available schemas/privileges at install; degrade gracefully to credit-only mode using ACCOUNT_USAGE. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
5. https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors

## Next Steps / Follow-ups

- Confirm which `SERVICE_TYPE` values we want to treat as “compute”, “serverless”, “platform services” for the app’s cost taxonomy (start with Snowflake’s enumerations from `METERING_HISTORY`).
- Decide how to present attribution: (a) pure warehouse cost; (b) estimated allocation to query_tag/user/role; (c) hybrid with policy guardrails.
- Add a small compatibility matrix: required privileges to read each view (`ACCOUNT_USAGE` vs `ORGANIZATION_USAGE`) for a Native App deployment.
