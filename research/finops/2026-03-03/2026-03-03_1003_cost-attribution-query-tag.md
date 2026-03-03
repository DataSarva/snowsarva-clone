# Research: FinOps - 2026-03-03

**Time:** 1003 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended showback/chargeback model is: use **object tags** to associate durable resources (warehouses/users) with a cost center, and use **query tags** when an app runs queries on behalf of users from multiple cost centers. [Snowflake docs: “Attributing cost”](https://docs.snowflake.com/en/user-guide/cost-attributing)
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** attributable to warehouse execution; it **excludes warehouse idle time** and **excludes non-warehouse costs** (data transfer, storage, cloud services, serverless features, AI token costs, etc.). It also excludes **short-running queries (<= ~100ms)**. [QUERY_ATTRIBUTION_HISTORY view](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history) and [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credits** by warehouse (compute + cloud services) with up to **~3 hour latency** for most columns and up to **~6 hours** for `CREDITS_USED_CLOUD_SERVICES`. It includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which is compute credits attributed to query execution **excluding idle time**. [WAREHOUSE_METERING_HISTORY view](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
4. A straightforward warehouse-level “idle compute” estimate is: `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)` over a time window. [WAREHOUSE_METERING_HISTORY example](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
5. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` is the org-level source of **daily usage in currency** with up to **72 hour latency**, retained indefinitely; **reseller customers can’t access it**. [USAGE_IN_CURRENCY_DAILY view](https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily)
6. Resource monitors can **notify/suspend warehouses** but are explicitly limited: they work for **warehouses only** (not serverless features / AI services). Their quotas include cloud services credits and **do not incorporate** the “daily 10% cloud services billing adjustment”. Schedules reset at **12:00 AM UTC** regardless of the time in `START_TIMESTAMP`. [Working with resource monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits; excludes idle; excludes <=~100ms queries; latency up to ~8h. [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits; has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (no idle). Latency up to ~180 min (some cols up to 6h). [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Maps tags to objects (warehouses/users/etc.) for showback. Mentioned as join target in attribution examples. [Docs](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily cost in currency; up to 72h latency; reseller limitation. [Docs](https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily) |
| `RESOURCE MONITOR` (object) | Object | N/A | Alerts/suspends warehouses only; quota includes cloud services and ignores 10% billing adjustment. [Docs](https://docs.snowflake.com/en/user-guide/resource-monitors) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Fully-loaded compute by tag” report**: attribute warehouse compute credits to `QUERY_TAG` (or user tag) and **allocate idle compute** proportionally so totals reconcile to warehouse metered compute. (Artifact SQL below.)
2. **Latency-aware UX**: surface “freshness” per metric (e.g., `QUERY_ATTRIBUTION_HISTORY` up to 8h; `USAGE_IN_CURRENCY_DAILY` up to 72h). Show a “data completeness” indicator per panel.
3. **Governance gap detection**: list top `QUERY_TAG = ''/NULL` (“untagged”) costs + top untagged users/warehouses (via TAG_REFERENCES joins). This makes tag hygiene operational.

## Concrete Artifacts

### SQL draft: Daily chargeback by QUERY_TAG with idle allocation (reconciles to warehouse compute)

Goal: for a given date range, compute “fully-loaded” warehouse compute credits per `query_tag` by:
- using `QUERY_ATTRIBUTION_HISTORY` for per-tag “active” compute credits, and
- allocating “idle compute” (from `WAREHOUSE_METERING_HISTORY`) across tags proportionally to their active credits.

```sql
-- Fully-loaded compute credits by QUERY_TAG (active + allocated idle)
-- Sources:
--  - ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (per-query compute credits; excludes idle)
--  - ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (warehouse compute metering; can infer idle)
-- Docs:
--  https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
--  https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

-- Parameters
SET start_date = DATEADD('day', -30, CURRENT_DATE());
SET end_date   = CURRENT_DATE();

WITH
-- 1) Active compute credits by (day, warehouse, tag)
active_by_tag AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS active_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_date
    AND start_time <  $end_date
  GROUP BY 1,2,3,4
),

-- 2) Total active compute per (day, warehouse)
active_totals AS (
  SELECT
    usage_date,
    warehouse_id,
    SUM(active_compute_credits) AS active_compute_credits_total
  FROM active_by_tag
  GROUP BY 1,2
),

-- 3) Metered compute per (day, warehouse) + inferred idle
metered_by_wh AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS metered_compute_credits,
    -- From docs: credits_attributed_compute_queries excludes idle.
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_date
    AND start_time <  $end_date
    AND warehouse_id > 0  -- avoid pseudo-warehouses if present
  GROUP BY 1,2,3
),

-- 4) Allocate idle compute to tags proportionally to active compute
fully_loaded AS (
  SELECT
    a.usage_date,
    a.warehouse_id,
    a.warehouse_name,
    a.query_tag,
    a.active_compute_credits,
    w.idle_compute_credits,
    w.metered_compute_credits,
    t.active_compute_credits_total,
    IFF(t.active_compute_credits_total = 0,
        0,
        a.active_compute_credits / t.active_compute_credits_total * w.idle_compute_credits
    ) AS allocated_idle_compute_credits,
    a.active_compute_credits +
      IFF(t.active_compute_credits_total = 0,
          0,
          a.active_compute_credits / t.active_compute_credits_total * w.idle_compute_credits
      ) AS fully_loaded_compute_credits
  FROM active_by_tag a
  JOIN active_totals t
    ON a.usage_date = t.usage_date
   AND a.warehouse_id = t.warehouse_id
  JOIN metered_by_wh w
    ON a.usage_date = w.usage_date
   AND a.warehouse_id = w.warehouse_id
)

SELECT
  usage_date,
  query_tag,
  ROUND(SUM(active_compute_credits), 6) AS active_compute_credits,
  ROUND(SUM(allocated_idle_compute_credits), 6) AS allocated_idle_compute_credits,
  ROUND(SUM(fully_loaded_compute_credits), 6) AS fully_loaded_compute_credits
FROM fully_loaded
GROUP BY 1,2
ORDER BY 1 DESC, fully_loaded_compute_credits DESC;
```

Notes:
- This is compute-only; it does **not** include cloud services, serverless features, storage, transfer, or AI token costs (by design, per Snowflake docs). [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
- If a warehouse has no rows in `QUERY_ATTRIBUTION_HISTORY` for a day (e.g., only short queries <=~100ms, or incomplete attribution), you’ll see `active_compute_credits_total = 0` and idle allocation becomes 0. In the app, this should be flagged as “not allocatable / missing attribution coverage”. [QUERY_ATTRIBUTION_HISTORY usage notes](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Per-query attribution excludes <=~100ms queries. | Some workloads (high-QPS short queries) may show as “untagged / unallocated” or lower than metered totals, requiring explicit “coverage” handling. | Confirm in account using known short-query patterns; compare `WAREHOUSE_METERING_HISTORY` totals vs sum of `QUERY_ATTRIBUTION_HISTORY`. [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history) |
| Organization-wide cost in currency is delayed (up to 72h) and might be unavailable for reseller customers. | App needs a fallback to credits-only and/or account-level metering without currency. | Detect ORGADMIN privileges + view availability; show “currency unavailable” state. [Docs](https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily) |
| Resource monitors ignore daily 10% cloud services billing adjustment but include cloud services credits in quota. | Alerts/suspends may trigger “early” relative to billed spend; quotas need buffers. | Document to users; recommend 90% notify threshold buffers. [Docs](https://docs.snowflake.com/en/user-guide/resource-monitors) |

## Links & Citations

1. Snowflake docs: Attributing cost — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: QUERY_ATTRIBUTION_HISTORY view — https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake docs: WAREHOUSE_METERING_HISTORY view — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. Snowflake docs: USAGE_IN_CURRENCY_DAILY view — https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
5. Snowflake docs: Working with resource monitors — https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Convert the SQL draft into a materialized “fact_cost_allocation_daily” table or dynamic table inside the Native App’s consumer account, with a partition key on `usage_date` + clustering on `(usage_date, query_tag)`.
- Add a “coverage dashboard” showing: metered compute credits vs attributed compute credits vs inferred idle vs unallocated remainder.
- Explore organization-level metering reconciliation requirements (e.g., required `ALTER SESSION SET TIMEZONE = UTC` for reconciling ACCOUNT_USAGE vs ORG_USAGE per docs). [WAREHOUSE_METERING_HISTORY usage notes](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
