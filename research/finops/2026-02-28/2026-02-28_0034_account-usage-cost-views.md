# Research: FinOps - 2026-02-28

**Time:** 00:34 UTC  
**Topic:** ACCOUNT_USAGE / ORG_USAGE cost & attribution primitives (metering + tags + idle time)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credits (compute + cloud services) for up to **365 days**, and includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which excludes **warehouse idle time**. 
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits that are closer to “what was billed”, including `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (a negative rebate) and `CREDITS_BILLED` (the sum including the adjustment).
3. Snowflake documentation explicitly notes: cloud services credits are **only billed** if daily cloud services consumption exceeds **10%** of daily warehouse usage; many dashboards/views show credits consumed without this daily adjustment; `METERING_DAILY_HISTORY` is the recommended source for the billed amount.
4. Snowflake’s recommended cost attribution approach is: use **object tags** (warehouses/users) and/or **query tags** (per session/queries) and join them with `TAG_REFERENCES` plus metering/attribution views.
5. `QUERY_ATTRIBUTION_HISTORY` is available for an **individual account** (ACCOUNT_USAGE only; no org-wide equivalent) and represents per-query warehouse execution costs but **does not include idle time**.
6. To reconcile ACCOUNT_USAGE with ORGANIZATION_USAGE cost views, Snowflake recommends setting the session timezone to **UTC** (`ALTER SESSION SET TIMEZONE = UTC`).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle time); latency up to ~3h (cloud services column up to ~6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits billed + cloud services adjustment (`CREDITS_ADJUSTMENT_CLOUD_SERVICES` negative) and `CREDITS_BILLED`. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly metering across service types; can filter by `SERVICE_TYPE` for serverless, SCS, etc. (Referenced from “Exploring compute cost”.) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to map tags to objects (warehouse/user/etc) for showback/chargeback joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits; excludes idle time; used for attribution by user/query_tag; no ORG_USAGE equivalent. |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` | Views | `ORG_USAGE` | Org-wide cost rollups exist for many views; set session TZ to UTC when reconciling with ACCOUNT_USAGE equivalents. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-time cost dashboard (per warehouse, per day/week)**: compute `idle_cost = credits_used_compute - credits_attributed_compute_queries` from `WAREHOUSE_METERING_HISTORY` and rank warehouses by persistent idle.
2. **“Billed vs consumed” lens for cloud services**: surface `credits_used_cloud_services` vs `credits_adjustment_cloud_services` vs `billed_cloud_services` from `METERING_DAILY_HISTORY` to reduce false alarms where consumption is high but billing is rebated.
3. **Tag-based chargeback starter pack**: prebuilt queries that join `TAG_REFERENCES` to `WAREHOUSE_METERING_HISTORY` (dedicated warehouses) and `QUERY_ATTRIBUTION_HISTORY` (shared warehouses/users), with fallbacks for untagged objects.

## Concrete Artifacts

### Artifact: Canonical “Compute bill of materials” SQL (billed daily + idle estimate + tag showback)

This is a draft meant for the Native App’s internal metrics layer (run by ACCOUNTADMIN / MONITOR USAGE privileges as required).

```sql
-- Canonical daily compute bill of materials
-- Goal: produce a single daily table with:
--  (1) billed credits by service type (including cloud services adjustment)
--  (2) warehouse idle estimate
--  (3) optional tag-based showback for dedicated warehouses
--
-- Notes:
-- - Many views are in SNOWFLAKE.ACCOUNT_USAGE.
-- - For reconciliation vs ORG_USAGE, Snowflake recommends: ALTER SESSION SET TIMEZONE = UTC;

ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Daily billed credits by service type (closest to invoice semantics)
WITH billed_daily AS (
  SELECT
    usage_date,
    service_type,
    credits_used_compute,
    credits_used_cloud_services,
    credits_adjustment_cloud_services,
    credits_billed
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
),

-- 2) Warehouse idle estimate over the same period
--    (idle time is explicitly excluded from CREDITS_ATTRIBUTED_COMPUTE_QUERIES)
warehouse_idle_daily AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS credits_idle_estimate
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND end_time < CURRENT_TIMESTAMP()
    AND warehouse_id > 0  -- skip pseudo warehouses (e.g. CLOUD_SERVICES_ONLY)
  GROUP BY 1, 2, 3
),

-- 3) Optional: dedicated-warehouse showback via warehouse tags
--    Works best when warehouses are exclusively owned by a cost center.
warehouse_cost_by_tag AS (
  SELECT
    TO_DATE(wmh.start_time) AS usage_date,
    COALESCE(tr.tag_value, 'untagged') AS cost_center,
    SUM(wmh.credits_used_compute) AS credits_used_compute
  FROM snowflake.account_usage.warehouse_metering_history wmh
  LEFT JOIN snowflake.account_usage.tag_references tr
    ON tr.domain = 'WAREHOUSE'
   AND tr.object_id = wmh.warehouse_id
   -- optionally constrain to a specific tag database/schema/name
   -- AND tr.tag_database = 'COST_MANAGEMENT'
   -- AND tr.tag_schema = 'TAGS'
   -- AND tr.tag_name = 'COST_CENTER'
  WHERE wmh.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND wmh.warehouse_id > 0
  GROUP BY 1, 2
)

SELECT
  bd.usage_date,
  bd.service_type,
  bd.credits_billed,
  bd.credits_used_compute,
  bd.credits_used_cloud_services,
  bd.credits_adjustment_cloud_services
FROM billed_daily bd
ORDER BY bd.usage_date DESC, bd.service_type;

-- Consumers can also join/union in warehouse_idle_daily and warehouse_cost_by_tag
-- depending on UI needs.
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ACCOUNT_USAGE view latency (3h typical; some columns longer) can make “today” partial. | Alerts/dashboards can flap. | Document minimum lookback windows; test freshness by comparing max timestamps to `CURRENT_TIMESTAMP()`. |
| `METERING_DAILY_HISTORY` is “closest to billed”, but actual invoicing includes contract pricing/editions/credits in currency. | Misalignment vs invoice totals in USD. | Pair with `USAGE_IN_CURRENCY_DAILY` where available and document conversion assumptions. |
| Idle estimate based on `credits_used_compute - credits_attributed_compute_queries` is warehouse-level and does not allocate to users/query tags. | Can’t do per-team idle allocation without additional modeling. | Offer optional proportional allocation method (doc shows patterns for distributing idle proportional to attributed usage). |
| Tag strategy requires consistent governance (who can set tags; replication if multi-account). | Showback/chargeback quality depends on tag hygiene. | Ship “untagged coverage” reports and onboarding checklist. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/user-guide/cost-attributing
4. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Add a second research pass on **`APPLICATION_DAILY_USAGE_HISTORY`** (native apps-specific) and how it can be used inside the FinOps Native App to separate app-driven usage from general warehouse usage.
- Validate which of these views are accessible from a Native App context vs requiring customer-granted privileges (and capture as an ADR).
