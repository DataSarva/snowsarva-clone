# Research: FinOps - 2026-03-01

**Time:** 17:20 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for up to the last **365 days**, including total credits, compute credits, and cloud services credits; view latency can be up to **180 minutes**, and cloud services columns can lag up to **6 hours**. 
2. Credits in `WAREHOUSE_METERING_HISTORY` (and `QUERY_HISTORY.credits_used_cloud_services`) may be **greater than billed credits** because they do **not** account for the cloud services billing adjustment; Snowflake documentation recommends using `METERING_DAILY_HISTORY` to determine credits actually billed.
3. `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` includes **query execution compute** but **excludes warehouse idle time**, enabling a first-pass “idle cost” calculation as: `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`.
4. Resource monitors are effective for **user-managed warehouses only** (including their supporting cloud services), can **notify** and/or **suspend** warehouses based on quotas/thresholds, but **do not track** serverless features / AI services spending; Snowflake recommends **Budgets** for those.
5. `SNOWFLAKE.ORGANIZATION_USAGE` is a shared database schema that provides historical usage data across **all accounts in an organization** with listed view latencies (commonly **24h**, some **2h** like `METERING_DAILY_HISTORY`). Some views are marked as **Premium** (org account only).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes compute + cloud services; latency up to 180 min (cloud services up to 6h). Idle time not included in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata; includes `QUERY_TAG`, `WAREHOUSE_NAME`, timings, bytes scanned/spilled, and `CREDITS_USED_CLOUD_SERVICES` (not billed-adjusted). |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORGANIZATION_USAGE` | Listed as 2h latency and 1y retention in org usage index; useful for cross-account daily billed-metering reconciliation. (Need to confirm exact columns for billed vs non-billed adjustment in a follow-up.) |
| Resource Monitor object | Object | Account | Controls/alerts on warehouse credit quota per interval; does not cover serverless/AI spend. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle-cost detector (warehouse & day/hour):** show where credits are spent on idle vs query execution using `WAREHOUSE_METERING_HISTORY` and highlight “always-on” warehouses.
2. **Query-tag cost attribution starter pack:** enforce/query-tag hygiene and produce leaderboards by `QUERY_TAG` / `ROLE_NAME` / `USER_NAME` / `WAREHOUSE_NAME` using `ACCOUNT_USAGE.QUERY_HISTORY` (with explicit caveat that per-query compute credits attribution is non-trivial without `QUERY_ATTRIBUTION_HISTORY` / Premium views).
3. **Org-level cost rollup (multi-account):** optional “org mode” that switches to `SNOWFLAKE.ORGANIZATION_USAGE` views (e.g., `METERING_DAILY_HISTORY`) for consolidated reporting when the customer is on an organization account.

## Concrete Artifacts

### SQL Draft: Idle Cost by Warehouse (last N days)

Uses Snowflake’s documented definition of `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (execution only) to approximate idle.

```sql
-- Idle compute credits by warehouse for the last 10 days.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   * Hourly data; view can be delayed up to ~3h (cloud services up to ~6h)
--   * Idle = compute credits not attributed to query execution

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start_utc,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -10, CURRENT_TIMESTAMP())
)
SELECT
  warehouse_name,
  DATE_TRUNC('day', hour_start_utc) AS day_utc,
  SUM(credits_used_compute) AS compute_credits,
  SUM(credits_attributed_compute_queries) AS query_execution_credits,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_compute_credits,
  IFF(SUM(credits_used_compute) = 0, NULL,
      (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / SUM(credits_used_compute)
  ) AS idle_ratio
FROM hourly
GROUP BY 1, 2
ORDER BY idle_compute_credits DESC;
```

### Pseudocode: “Cost Guardrails” Recommendation Engine

```text
Inputs:
  - account_usage.warehouse_metering_history (hourly)
  - account_usage.query_history (query_tag, role, warehouse, elapsed/queued times)
  - (optional org mode) organization_usage.metering_daily_history

Steps:
  1) Compute idle_ratio per warehouse per day; flag if idle_ratio > threshold AND compute_credits > floor.
  2) For flagged warehouses, check query_history for queued_overload_time spikes → recommend multi-cluster / resize.
  3) If many short queries and high idle → recommend auto-suspend/auto-resume tuning + smaller size.
  4) If many queries lack query_tag → recommend tagging policy & enforcement (CI templates, session param wrappers).
Outputs:
  - ranked recommendations with: expected savings (credits), confidence, evidence links (supporting metrics).
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Idle cost” computed from `credits_used_compute - credits_attributed_compute_queries` is an approximation; doesn’t allocate idle to workloads/users. | Could mislead attribution if presented as “waste” without context. | Validate against Snowflake examples + cross-check with customer ops realities (24/7 SLAs). |
| “Billed credits” reconciliation requires `METERING_DAILY_HISTORY` and understanding cloud services adjustment. | App could disagree with invoices if we present raw `CREDITS_USED*`. | Pull and document exact billed columns/logic from `METERING_DAILY_HISTORY` docs next. |
| Organization Usage is not always available (org account + Premium views). | Features may be unavailable for many customers. | Detect availability at install-time; degrade gracefully to account-level only. |
| Resource monitors do not cover serverless/AI costs. | Guardrails could miss a growing category of spend. | Add Budgets integration path; document gap clearly in UI. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/user-guide/resource-monitors
4. https://docs.snowflake.com/en/sql-reference/organization-usage

## Next Steps / Follow-ups

- Fetch and summarize the **exact** columns/semantics of `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` and/or `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` for invoice reconciliation (billed credits vs raw).
- Evaluate whether `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (Premium) can unlock credible per-workload cost attribution beyond heuristics.
- Draft UI wireframe for “Idle Cost” + “Tag Hygiene” dashboards and decide default thresholds (industry sensible defaults + customer override).
