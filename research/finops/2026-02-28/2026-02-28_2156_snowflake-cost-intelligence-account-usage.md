# Research: FinOps - 2026-02-28

**Time:** 21:56 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for up to **365 days** and includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (which excludes idle time). Latency can be up to 3 hours (and up to 6 hours for cloud services credits). [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) for the last 365 days, but explicitly **excludes warehouse idle time** and excludes short-running queries (≈ <=100ms). Latency can be up to 8 hours. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
3. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily** usage in currency (and units) at the organization level; its data can take up to **72 hours** to arrive and can change until month close. It is not available to reseller customers. [https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily](https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily)
4. Snowflake’s recommended approach for chargeback/showback is to use **object tags** (e.g., tag warehouses/users) and **query tags** (tag application queries) and then join usage/cost views (e.g., `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, `QUERY_ATTRIBUTION_HISTORY`). There is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`. [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
5. When reconciling `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` with `ORGANIZATION_USAGE` views, Snowflake documents that you should set the session timezone to UTC first. [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits for 365 days; includes attributed compute query credits and supports computing idle credits as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`; reconcile with org usage by setting `TIMEZONE=UTC`. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query warehouse compute credits; excludes idle time and short queries (≈<=100ms). No org-wide equivalent. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to map object tags to warehouses/users for attribution joins (described in cost attribution doc). |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily org-level usage in currency; includes `RATING_TYPE`, `SERVICE_TYPE`, `USAGE`, `USAGE_IN_CURRENCY`; latency up to 72h; mutable until month close. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost visibility per warehouse (credits + $):** compute hourly idle credits from `WAREHOUSE_METERING_HISTORY`, roll to daily, then apply an **effective $/credit** derived from `USAGE_IN_CURRENCY_DAILY` (org-level) for `RATING_TYPE='compute'` + `SERVICE_TYPE='WAREHOUSE_METERING'` (see artifact). This gives a concrete “idle burn” report.
2. **Query-tag based chargeback that reconciles to warehouse bill:** sum `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG`, then allocate the **idle remainder** proportionally (as Snowflake’s own examples suggest), to produce a complete chargeback that matches warehouse compute credits.
3. **“Data freshness” guardrails for FinOps dashboards:** encode view-specific latencies (3h/6h for warehouse metering, 8h for query attribution, 72h for currency daily) so the Native App UI warns users when their selected date range includes periods likely to be incomplete.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily warehouse cost model (credits → idle → dollars)

Goal: produce daily warehouse compute credits, daily idle credits, and estimate daily $ for warehouse compute using org-level currency data.

```sql
-- Purpose:
--   1) Compute warehouse compute credits and idle credits from ACCOUNT_USAGE at daily grain.
--   2) Compute effective $/credit for WAREHOUSE_METERING from ORG_USAGE at daily grain.
--   3) Apply $/credit to estimate dollars for daily warehouse compute + idle.
--
-- Notes (from Snowflake docs):
--   - Set session timezone to UTC when reconciling with ORG_USAGE.
--   - ORG_USAGE.USAGE_IN_CURRENCY_DAILY latency can be up to 72 hours.
--   - ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY latency can be up to 3 hours (6 for cloud services credits).

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Daily warehouse credits (compute + idle) from ACCOUNT_USAGE
WITH wh_hourly AS (
  SELECT
      warehouse_id,
      warehouse_name,
      start_time,
      credits_used_compute,
      credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
),
wh_daily AS (
  SELECT
      DATE_TRUNC('day', start_time) AS usage_date,
      warehouse_id,
      warehouse_name,
      SUM(credits_used_compute) AS compute_credits,
      SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits
  FROM wh_hourly
  GROUP BY 1,2,3
),

-- 2) Effective $/credit for WAREHOUSE_METERING from ORG_USAGE
-- (Filters depend on columns documented for USAGE_IN_CURRENCY_DAILY.)
rate_daily AS (
  SELECT
      usage_date,
      currency,
      SUM(usage) AS credits,                 -- when rating_type='compute', unit is credits
      SUM(usage_in_currency) AS dollars,
      CASE WHEN SUM(usage) = 0 THEN NULL ELSE SUM(usage_in_currency) / SUM(usage) END AS dollars_per_credit
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
    AND rating_type = 'compute'
    AND service_type = 'WAREHOUSE_METERING'
    AND is_adjustment = FALSE
  GROUP BY 1,2
)

SELECT
    w.usage_date,
    w.warehouse_name,
    w.compute_credits,
    w.idle_credits,
    r.currency,
    r.dollars_per_credit,
    (w.compute_credits * r.dollars_per_credit) AS est_compute_dollars,
    (w.idle_credits   * r.dollars_per_credit) AS est_idle_dollars
FROM wh_daily w
LEFT JOIN rate_daily r
  ON w.usage_date = r.usage_date
ORDER BY w.usage_date DESC, est_compute_dollars DESC;
```

Why this matters for the Native App:
- This produces a “warehouse cost ledger” at daily grain where credits and dollars are aligned and idle burn is first-class.
- It also makes the org-level dependency explicit (currency attribution requires ORG_USAGE access + higher latency).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `USAGE_IN_CURRENCY_DAILY` filters (`RATING_TYPE='compute'`, `SERVICE_TYPE='WAREHOUSE_METERING'`) correctly reflect the same credit pool as `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | If mismatched, $ estimates won’t reconcile even if credits do | Validate on a known closed month by comparing total warehouse compute credits * $/credit vs org statement totals for WAREHOUSE_METERING. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short queries (≈<=100ms) | Per-query rollups won’t sum to warehouse compute credits; chargeback must allocate residual | Confirm by comparing summed `credits_attributed_compute` to `WAREHOUSE_METERING_HISTORY.credits_used_compute` for same period. |
| Latency differs by view (3h/6h/8h/72h) | Dashboards can show partial data and trigger false alerts | Implement “freshness windows” and show last-available timestamps per source. |
| ORG usage access and reseller restrictions | Some customers cannot see currency views; app must degrade gracefully | Detect availability of `ORGANIZATION_USAGE` views/roles and fall back to credits-only mode. |

## Links & Citations

1. Snowflake docs — Attributing cost (tags, query tags, joins; no org-wide query attribution): [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
2. Snowflake docs — `QUERY_ATTRIBUTION_HISTORY` view (per-query compute credits; excludes idle; <=~100ms excluded; latency): [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
3. Snowflake docs — `WAREHOUSE_METERING_HISTORY` view (hourly warehouse credits; idle-time note; timezone-to-UTC for reconciliation): [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
4. Snowflake docs — `USAGE_IN_CURRENCY_DAILY` view (daily usage + currency; 72h latency; mutable until month close): [https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily](https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily)

## Next Steps / Follow-ups

- Validate the `USAGE_IN_CURRENCY_DAILY` filtering strategy on a closed month to ensure $/credit aligns with WAREHOUSE_METERING credits.
- Extend the SQL draft into a canonical “cost ledger” model the Native App can materialize (daily grain + dimensions: warehouse, query_tag, user, role, cost_center tag).
- Add a “freshness” component to the UI to avoid misleading near-real-time displays (especially for currency views).
