# Research: FinOps - 2026-02-28

**Time:** 1533 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query attributed warehouse compute credits** (not idle time) for the last 365 days; it **excludes short-running queries (<= ~100ms)** and can have up to **8 hours latency**. It does not include cloud services, storage, data transfer, serverless features, or AI-token costs. (https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` is the **hourly warehouse credit usage** source for the last 365 days. `CREDITS_USED` does **not** account for the daily cloud-services billing adjustment; to determine billed credits, Snowflake directs users to `METERING_DAILY_HISTORY`. The view includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which excludes idle time. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily usage in credits and currency** at the org level, including billing metadata (`BILLING_TYPE`, `RATING_TYPE`, `SERVICE_TYPE`, `IS_ADJUSTMENT`). Data can lag up to **72 hours** and may change until month close. (https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily)
4. Snowflake **resource monitors** can monitor/suspend **warehouse** credit usage only; they **cannot** track serverless/AI services. Resource monitors count cloud-services credits without the daily 10% adjustment even if those credits are never billed. (https://docs.snowflake.com/en/user-guide/resource-monitors)
5. Snowflake **budgets** define a monthly credit spending limit for an account or a custom object group; they send notifications when spend is **projected** to exceed the limit and can notify via email, cloud queues, or webhooks. Budgets can call user-defined stored procedures at thresholds/cycle start; lowering refresh interval to 1 hour increases budget compute cost by **12x**. (https://docs.snowflake.com/en/user-guide/budgets)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query **warehouse** compute cost attribution; excludes idle time and short queries (<= ~100ms); latency up to ~8h. |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY | View | ACCOUNT_USAGE | Needed for dimensions (query_type, user/role, bytes scanned, timings) and joining to tags/hashes; latency up to ~45 min per docs (not extracted here). |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits per warehouse; includes `CREDITS_USED_*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; `CREDITS_USED` not adjusted for billed cloud services. |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Required for **billed** credits due to cloud services daily adjustment (referenced by WAREHOUSE_METERING_HISTORY docs). |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | View | ORG_USAGE | Daily credits + currency + billing/service metadata; latency up to 72h; org-level. |
| Snowflake Budgets (SNOWFLAKE.CORE.BUDGET class) | Object | Snowflake app/object | Monthly limit + forecast notifications; can trigger stored procedures on thresholds/cycle-start; low-latency mode cost multiplier. |
| RESOURCE MONITOR | Object | Account-level object | Warehouse-only credit quota/notifications/suspend actions; counts cloud services credits without billed adjustment. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost Attribution Lens” (warehouse-hour → query-tag):** dashboard + API that reports (a) metered warehouse credits/hour, (b) query-attributed credits/hour, and (c) *idle delta* = compute metered - attributed. This gives operators an immediate “are we burning idle?” signal using only Snowflake-provided views.
2. **“Credits → Currency Normalizer” (daily):** join account-level credit meters (warehouse + serverless where possible) to org-level `USAGE_IN_CURRENCY_DAILY` to estimate $/credit effective rates and reconcile anomalies per service_type/billing_type.
3. **Guardrails recommender:** propose when to use **resource monitors** vs **budgets** (warehouse-only hard stop vs broader forecasting with serverless/AI). Include warning that resource monitors can alert on cloud services credits that might not be billed (daily 10% adjustment not applied).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: SQL draft — Daily cost attribution summary (credits + currency)

Goal: produce a daily table that combines:
- warehouse compute metered credits
- per-query attributed credits (sum)
- idle credits (difference)
- org currency totals for `WAREHOUSE_METERING` (for reconciliation)

```sql
-- NOTE: This is a draft skeleton for the Native App to generate daily summaries.
-- Assumptions/unknowns:
-- - ORG_USAGE availability requires ORGADMIN-like privileges in many orgs.
-- - Mapping ACCOUNT_USAGE warehouse usage to ORG_USAGE currency is approximate unless you align timezone + account identifiers.
-- - WAREHOUSE_METERING_HISTORY.CREDITS_USED_* are not billed-adjusted for cloud services; billed compute requires METERING_DAILY_HISTORY.

ALTER SESSION SET TIMEZONE = UTC; -- required when reconciling ACCOUNT_USAGE ↔ ORG_USAGE per Snowflake docs.

-- 1) Daily metered credits per warehouse (compute only)
WITH wh_metered_daily AS (
  SELECT
    TO_DATE(start_time)                        AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute)                 AS credits_compute_metered,
    SUM(credits_used_cloud_services)          AS credits_cloud_services_consumed,
    SUM(credits_used)                         AS credits_total_consumed,
    SUM(credits_attributed_compute_queries)   AS credits_attributed_compute_queries_hourly
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
),

-- 2) Daily per-query attributed credits (query-level warehouse compute only)
query_attrib_daily AS (
  SELECT
    TO_DATE(start_time)                 AS usage_date,
    warehouse_id,
    warehouse_name,
    COALESCE(query_tag, '<unset>')      AS query_tag,
    SUM(credits_attributed_compute)     AS credits_attributed_compute,
    SUM(COALESCE(credits_used_query_acceleration, 0)) AS credits_qas
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3,4
),

-- 3) Roll up attributed credits by warehouse/day (to compute idle delta)
query_attrib_rollup AS (
  SELECT
    usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_attributed_compute) AS credits_attributed_compute_sum
  FROM query_attrib_daily
  GROUP BY 1,2,3
),

-- 4) Org-level currency (daily)
org_currency_daily AS (
  SELECT
    usage_date,
    account_locator,
    account_name,
    currency,
    rating_type,
    service_type,
    billing_type,
    is_adjustment,
    SUM(usage)             AS usage_units,
    SUM(usage_in_currency) AS usage_in_currency
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
    AND rating_type = 'compute'
  GROUP BY 1,2,3,4,5,6,7,8
)

SELECT
  w.usage_date,
  w.warehouse_id,
  w.warehouse_name,
  w.credits_compute_metered,
  COALESCE(q.credits_attributed_compute_sum, 0) AS credits_attributed_compute_sum,
  (w.credits_compute_metered - COALESCE(q.credits_attributed_compute_sum, 0)) AS credits_idle_delta,
  w.credits_cloud_services_consumed,
  w.credits_total_consumed,
  -- org currency join is intentionally left as an exercise (requires reliable account_locator mapping).
  NULL::NUMBER(38,2) AS est_usd_for_warehouse_compute
FROM wh_metered_daily w
LEFT JOIN query_attrib_rollup q
  ON w.usage_date = q.usage_date
 AND w.warehouse_id = q.warehouse_id
ORDER BY 1 DESC, 3;
```

### Artifact: ADR (mini) — “Cost attribution truth sources”

**Decision:**
- Use `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` as the hour-grain “meter” for warehouse credits.
- Use `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` as the query-grain “allocation” signal.
- Use `ORG_USAGE.USAGE_IN_CURRENCY_DAILY` for billing/currency reconciliation (when available), not for near-real-time dashboards.

**Rationale:**
- Snowflake explicitly positions `QUERY_ATTRIBUTION_HISTORY` as warehouse compute attribution per query, with known exclusions and latency.
- Snowflake explicitly positions `WAREHOUSE_METERING_HISTORY` as hourly usage for warehouses and notes billed-adjustment caveats.
- Org currency view includes billing metadata, but is higher latency and can change until month close.

**Consequences:**
- “Idle delta” becomes a first-class metric: (metered compute credits) - (sum query-attributed compute credits).
- Cloud services billing adjustment must be handled via `METERING_DAILY_HISTORY` if reconciling to invoices.
- UI must label “consumed credits” vs “billed credits” explicitly.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE views may not be available to the app/runtime role in many customer orgs. | Currency reconciliation may be impossible in-app; require optional setup steps. | Document required roles/privileges; implement graceful degradation to credits-only mode. |
| `QUERY_ATTRIBUTION_HISTORY` excludes short queries and idle time by definition. | “Per-query cost” will undercount total compute if many short queries or heavy idle. | Provide “coverage” metrics: attributed credits / metered credits; show idle delta explicitly. |
| Resource monitors count cloud services credits without daily billed adjustment. | Alerts may trigger even when customers aren’t billed for those cloud services credits. | Label monitor-based alerts as “consumption-based” not “invoice-based”; cross-check with `METERING_DAILY_HISTORY` for billing. |
| Data latency: 45m–8h for key views; up to 72h for currency. | Near-real-time FinOps dashboards will have gaps. | Use freshness indicators; prefer WAREHOUSE_METERING_HISTORY for faster signals vs currency. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
4. https://docs.snowflake.com/en/user-guide/resource-monitors
5. https://docs.snowflake.com/en/user-guide/budgets

## Next Steps / Follow-ups

- Extract + validate `METERING_DAILY_HISTORY` semantics (billed cloud services adjustment) and draft reconciliation SQL end-to-end.
- Decide app posture for org-level currency: optional setup vs required capability.
- Add a data model for “coverage” and “freshness” so the UI can surface accuracy constraints plainly.
