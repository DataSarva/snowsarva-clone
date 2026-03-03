# Research: FinOps - 2026-03-03

**Time:** 18:44 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage by warehouse for the past **365 days**; the view’s latency is up to **~180 minutes**, except for some cloud-services related fields which can lag more. (See “Usage notes” + column docs.)
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is explicitly documented as a sum of compute + cloud services credits **that may exceed billed credits** because it does not account for the cloud services adjustment; Snowflake recommends reconciling billed credits using `ACCOUNT_USAGE.METERING_DAILY_HISTORY`. 
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides daily credits used and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative) and `CREDITS_BILLED` which rolls up compute + cloud services + adjustment; this is the cleanest “billed credits per day” base table for chargeback that must align to invoices.
4. Snowflake’s recommended approach for **cost attribution / showback** is: (a) use **object tags** to associate warehouses/users to cost centers, and (b) use **query tags** to attribute individual queries (especially when a shared application executes queries on behalf of multiple groups). 
5. Snowflake provides `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` specifically for attributing **warehouse compute costs to queries**; per Snowflake docs: cost per query is based on warehouse credit usage during execution, and it **excludes idle time** and excludes non-warehouse costs (storage, transfers, serverless, AI tokens, etc.).
6. Resource monitors can notify and/or suspend **user-managed warehouses** when thresholds are reached, but are explicitly **not** for serverless features; Snowflake directs users to budgets for monitoring serverless/AI services spend.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (365d). Has `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and (newer) `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to support idle-time calculation. Latency up to ~3h; cloud services columns may lag more. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Hourly credits by warehouse across org accounts (365d). Latency can be up to 24h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits including cloud services adjustment (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`) and `CREDITS_BILLED`. Filter by `SERVICE_TYPE` to split warehouse/serverless/etc. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Org-wide daily billed credits by account (UTC usage_date). Useful for org chargeback dashboards. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Needed to join tags to warehouses/users for cost center attribution (“Viewing cost by tag in SQL”). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute attribution for warehouse compute (excludes idle time + non-warehouse costs). |
| `RESOURCE MONITOR` object + `CREATE RESOURCE MONITOR` | Object + DDL | n/a | Can enforce thresholds on warehouses. Snowflake docs: resource monitors work for warehouses only; budgets for serverless/AI. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Billed vs Consumed” explanation panel** in the app: show `WAREHOUSE_METERING_HISTORY` (consumed) alongside `METERING_DAILY_HISTORY.CREDITS_BILLED` (billed) to reduce confusion and prevent false alarms when cloud services adjustment applies.
2. **Tag-first chargeback**: a small workflow + checks that (a) validates required warehouse/user tags exist, (b) computes `credits_used_compute` by tag value, and (c) lists “untagged” spend explicitly.
3. **Query-tag governance lint**: detect sessions/applications that do not set `QUERY_TAG` (or use non-JSON / inconsistent formats) and quantify “untagged query attribution” using `QUERY_ATTRIBUTION_HISTORY`.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Minimal cost attribution mart (credits) for a Native App

Goal: produce a stable table that the app UI can read quickly (instead of repeatedly scanning raw `ACCOUNT_USAGE` views), and that supports:
- warehouse credits by warehouse name
- showback by object tags (warehouse cost center)
- showback by query tags (app-level tagging)
- explicit handling of idle-time attribution (optional)

```sql
-- NOTE: This is a *draft* reference query.
-- It assumes you have privileges to read ACCOUNT_USAGE views.
-- Consider materializing incrementally to avoid scanning 365d repeatedly.

-- 0) Always reconcile cross-schema / org views in UTC when needed.
ALTER SESSION SET TIMEZONE = 'UTC';

-- 1) Monthly compute credits by warehouse (consumed compute credits; not billed adjustments).
CREATE OR REPLACE VIEW FINOPS_MART.V_WH_COMPUTE_CREDITS_MONTH AS
SELECT
  DATE_TRUNC('month', start_time) AS month,
  warehouse_id,
  warehouse_name,
  SUM(credits_used_compute) AS credits_used_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('month', -12, CURRENT_TIMESTAMP())
GROUP BY 1,2,3;

-- 2) Join warehouse tags for cost center showback.
-- Snowflake docs show joining TAG_REFERENCES.object_id to WAREHOUSE_METERING_HISTORY.warehouse_id
-- with domain='WAREHOUSE'.
CREATE OR REPLACE VIEW FINOPS_MART.V_WH_COMPUTE_CREDITS_BY_TAG_MONTH AS
SELECT
  wh.month,
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wh.credits_used_compute) AS credits_used_compute
FROM FINOPS_MART.V_WH_COMPUTE_CREDITS_MONTH wh
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  ON wh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
GROUP BY 1,2,3;

-- 3) Query attribution (excluding idle time) by query_tag.
-- Empty query_tag is treated as 'untagged'.
CREATE OR REPLACE VIEW FINOPS_MART.V_QUERY_ATTRIBUTION_BY_QUERY_TAG_MONTH AS
SELECT
  DATE_TRUNC('month', start_time) AS month,
  COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
  SUM(credits_attributed_compute) AS credits_attributed_compute,
  SUM(credits_used_query_acceleration) AS credits_used_qas
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('month', -12, CURRENT_TIMESTAMP())
GROUP BY 1,2;

-- 4) Optional: distribute idle time back to query_tag proportionally.
-- Uses Snowflake doc pattern: total warehouse compute credits (billing base)
-- multiplied by each tag's fraction of attributed credits.
CREATE OR REPLACE VIEW FINOPS_MART.V_QUERY_ATTRIBUTION_BY_QUERY_TAG_MONTH_INCL_IDLE AS
WITH
  wh_bill AS (
    SELECT
      DATE_TRUNC('month', start_time) AS month,
      SUM(credits_used_compute) AS wh_compute_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('month', -12, CURRENT_TIMESTAMP())
    GROUP BY 1
  ),
  tag_credits AS (
    SELECT
      DATE_TRUNC('month', start_time) AS month,
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
      SUM(credits_attributed_compute) AS attributed_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
    WHERE start_time >= DATEADD('month', -12, CURRENT_TIMESTAMP())
    GROUP BY 1,2
  ),
  totals AS (
    SELECT month, SUM(attributed_credits) AS sum_attributed
    FROM tag_credits
    GROUP BY 1
  )
SELECT
  tc.month,
  tc.query_tag,
  CASE
    WHEN t.sum_attributed = 0 THEN 0
    ELSE (tc.attributed_credits / t.sum_attributed) * w.wh_compute_credits
  END AS compute_credits_including_idle
FROM tag_credits tc
JOIN totals t USING (month)
JOIN wh_bill w USING (month);

-- 5) Daily billed credits base (for “invoice-aligned” dashboards):
CREATE OR REPLACE VIEW FINOPS_MART.V_BILLED_CREDITS_DAILY AS
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -365, CURRENT_DATE());
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` views have latency (hours) | “Real-time” dashboards will be misleading; alerting windows must be tolerant | Confirm with docs for each view; communicate “data freshness” in UI. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time + excludes non-warehouse costs | Showback numbers won’t tie to bill unless we layer in idle allocation + serverless/AI costs | Validate by reconciling monthly totals vs `METERING_DAILY_HISTORY` and show reconciliation deltas explicitly. |
| Tag adoption is incomplete (“untagged” spend) | Chargeback story breaks without strong governance | Track untagged percentage and add onboarding checks in app. |
| Resource monitors do not cover serverless/AI services | If customers expect monitors to control all spend, they’ll be surprised | Surface a “controls coverage matrix” and recommend budgets for serverless/AI per Snowflake docs. |

## Links & Citations

1. `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly credits; notes about billed vs consumed; latency; idle-time calculation example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. `ACCOUNT_USAGE.METERING_DAILY_HISTORY` (daily billed credits including cloud services adjustment + `CREDITS_BILLED`): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Snowflake “Attributing cost” guide (recommended approach: object tags + query tags; use `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, `QUERY_ATTRIBUTION_HISTORY`): https://docs.snowflake.com/en/user-guide/cost-attributing
4. Snowflake “Working with resource monitors” (warehouse-only; budgets for serverless/AI): https://docs.snowflake.com/en/user-guide/resource-monitors
5. `CREATE RESOURCE MONITOR` syntax/behavior (triggers and limitations): https://docs.snowflake.com/en/sql-reference/sql/create-resource-monitor

## Next Steps / Follow-ups

- Decide if the Native App’s **canonical** cost number is (a) invoice-aligned billed credits (`METERING_DAILY_HISTORY.credits_billed`) or (b) “engineering consumed credits” (sum of warehouse metering + serverless usage views). Likely we need both and reconciliation.
- Add a small ADR for “Chargeback truth sources” + “idle time handling policy” (ignore vs allocate) to avoid ambiguous UI.
- Research next: Snowflake **budgets** object/model and which ACCOUNT_USAGE/ORG_USAGE views support budget events (needed because resource monitors don’t cover serverless/AI).
