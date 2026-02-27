# Research: FinOps - 2026-02-27

**Time:** 15:54 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + budgets + automation hooks)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for chargeback/showback is: **object tags** to associate resources/users to cost centers, plus **query tags** when the same application issues queries on behalf of multiple groups. (This supports shared-warehouse and shared-application scenarios.)
2. Within a single account, cost attribution in SQL commonly joins `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with metering views like `WAREHOUSE_METERING_HISTORY` (warehouse credits) and `QUERY_ATTRIBUTION_HISTORY` (credits attributed to queries). There is **no org-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`; it’s account-only.  
3. `QUERY_ATTRIBUTION_HISTORY` provides per-query compute attribution (and some related services like QAS credits), but explicitly **does not include** non-query costs like storage, data transfer, cloud services, serverless features, etc.; and it also **excludes warehouse idle time**. (Idle time can be redistributed with an additional calculation using `WAREHOUSE_METERING_HISTORY`.)
4. **Budgets** define a **monthly** spending limit (credits) for either an entire account or a custom group of objects; when forecasted spend is projected to exceed the limit, notifications can go to email, cloud queues, or webhooks.
5. Budgets have a default refresh latency “up to ~6.5 hours”; they can be configured as **low-latency (1 hour)** budgets, but this increases the compute cost of the budget (Snowflake states ~12x).
6. Budgets can be configured to call **user-defined stored procedures** at key points (threshold reached, cycle start), enabling automated actions like suspending warehouses or logging events.
7. A baseline set of warehouse “cost controls” that Snowflake repeatedly emphasizes includes `AUTO_SUSPEND`, `AUTO_RESUME`, statement timeouts, and resource monitors.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Lists objects with tags; used for chargeback joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Warehouse credit usage; join via `warehouse_id` for tagged allocation. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed credits; excludes idle time; account-only (no org view). |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Can identify root query id for hierarchical/procedure attribution. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query text, warehouse, user, timings; useful for explainability. |
| `SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS` | View | `ACCOUNT_USAGE` | Storage footprint + time travel/failsafe/clone retained; used for storage optimization patterns. |
| `BUDGET` (class/object) | Object | Snowflake feature | Budget admin/viewer roles; can trigger stored procedures; monthly intervals only. |
| `RESOURCE MONITOR` | Object | Snowflake feature | Can notify/suspend warehouses at thresholds; complements budgets. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag coverage” linter + dashboard**: surface (a) untagged warehouses/users, (b) top spend in `QUERY_ATTRIBUTION_HISTORY` with empty/untagged `QUERY_TAG`, and (c) drift (tag values outside allowed set). Output: tables + recommendations.
2. **Automated showback view pack**: create secure views for (i) credits by `cost_center` (warehouse tags), (ii) credits by query tag (app-level chargeback), and (iii) most expensive parameterized query templates via `query_parameterized_hash`.
3. **Budget action harness**: ship a reference stored procedure that budgets can call at thresholds to (a) write an audit event row, (b) optionally suspend specific warehouses, and (c) emit webhook via Snowflake notification integration (where supported/available). (Design to run inside customer account under least-privilege.)

## Concrete Artifacts

### Artifact: SQL draft — unified chargeback view (object tags + query tags)

Goal: produce a single “daily credits by cost_center” dataset that:
- attributes warehouse spend to tagged warehouses, and
- attributes shared warehouses / shared apps via query tags (when used).

Notes:
- This is a **draft**; exact join keys and availability depend on edition/region/retention windows.
- `QUERY_ATTRIBUTION_HISTORY` excludes idle time; this view reports *attributed* compute credits, not billed warehouse credits.

```sql
-- =====================================================================================
-- CHARGEBACK / SHOWBACK DRAFT
-- - Uses query-level attribution when QUERY_TAG is set
-- - Uses warehouse tag attribution for warehouse metering (for dedicated warehouses)
-- =====================================================================================

-- 1) Canonical dimension: cost_center tags on warehouses
WITH wh_cost_center AS (
  SELECT
      object_id              AS warehouse_id,
      object_name            AS warehouse_name,
      COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_name = 'COST_CENTER'
    -- optionally constrain to your tag database/schema if you standardize:
    -- AND tag_database = 'COST_MANAGEMENT'
    -- AND tag_schema   = 'TAGS'
),

-- 2) Warehouse metering: billed-ish warehouse compute credits (includes idle time)
wh_credits AS (
  SELECT
      wm.warehouse_id,
      DATE_TRUNC('DAY', wm.start_time) AS day,
      SUM(wm.credits_used_compute)     AS credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wm
  WHERE wm.start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),

-- 3) Query attribution: per-query compute (excludes idle time), grouped by query_tag
qtag_credits AS (
  SELECT
      DATE_TRUNC('DAY', qah.start_time) AS day,
      COALESCE(NULLIF(qah.query_tag, ''), 'untagged') AS query_tag,
      SUM(qah.credits_attributed_compute) AS credits_attributed_compute,
      SUM(qah.credits_used_query_acceleration) AS credits_used_qas
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  WHERE qah.start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
)

-- 4) Output: two lenses (warehouse-tagged + query-tagged) for downstream BI
SELECT
    'WAREHOUSE_TAG' AS attribution_mode,
    c.day,
    wc.cost_center,
    wc.warehouse_name AS entity,
    c.credits_used_compute AS credits
FROM wh_credits c
LEFT JOIN wh_cost_center wc
  ON c.warehouse_id = wc.warehouse_id

UNION ALL

SELECT
    'QUERY_TAG' AS attribution_mode,
    q.day,
    -- Derive cost_center if you embed it in query_tag like 'COST_CENTER=finance'
    -- else keep NULL and let consumers parse
    NULL AS cost_center,
    q.query_tag AS entity,
    q.credits_attributed_compute AS credits
FROM qtag_credits q
;
```

### Artifact: ADR sketch — “Budgets + stored procedure actions” for FinOps automation

**Decision:** Use Snowflake Budgets (monthly) as the primary “guardrail + alerting + integration” plane, and implement automated actions via user-defined stored procedures called by budgets.

**Why:** Budgets can notify via email/queue/webhook and can trigger stored procedures; this enables programmable responses and creates a clear boundary between (a) detection/forecast and (b) enforcement.

**Consequences / Implementation notes:**
- Stored procedures must run with tightly scoped privileges (minimize ability to suspend warehouses globally).
- Budget refresh intervals can be up to ~6.5 hours; for “fast spike” protection we still need warehouse-level controls (e.g., statement timeouts, resource monitors) and anomaly detection.
- When using tags to define custom budget scope, Snowflake documents that tag changes can take up to hours to reflect; do not rely on near-real-time tag changes for emergency gating.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` availability/retention differs by account and may not cover all needed time windows | Limits long-term trend analysis | Confirm in target accounts + document min requirements. |
| Per-query attribution excludes idle time and non-query costs (storage, transfers, cloud services, serverless features) | Showback may under-represent “true bill” per group | Pair with warehouse metering and separate storage allocation model. |
| Org-wide chargeback is limited (no org-wide `QUERY_ATTRIBUTION_HISTORY`) | Multi-account apps need per-account rollups | Build aggregator pattern (one pipeline per account → central report). |
| Budget refresh interval latency (up to ~6.5h) means alerts/actions can be delayed | Slow reaction to fast spend spikes | Complement with warehouse-level timeouts/resource monitors + anomaly detection. |
| Tag governance (coverage + allowed values) is operationally hard | Gaps in attribution | Ship tag coverage checks + automation for tag application. |

## Links & Citations

1. Snowflake docs: **Attributing cost** (object tags + query tags; views used; `QUERY_ATTRIBUTION_HISTORY` caveats) — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: **Monitor credit usage with budgets** (monthly budgets, notifications, refresh intervals, stored procedure actions) — https://docs.snowflake.com/en/user-guide/budgets
3. Snowflake developer guide: **Getting Started with Cost and Performance Optimization** (warehouse controls: auto_suspend/resume, statement timeout, resource monitors; `ACCOUNT_USAGE` examples) — https://www.snowflake.com/en/developers/guides/getting-started-cost-performance-optimization/

## Next Steps / Follow-ups

- Convert the SQL draft into a versioned schema (`FINOPS_INTELLIGENCE`) with secure views + documented semantics (“billed” vs “attributed”).
- Add an “idle time reallocation” option (warehouse metering total minus sum attributed → distribute pro-rata by query credits or by time).
- Research: how budgets behave for **objects owned by a Snowflake Native App** (custom budget docs indicate special behavior); decide how the native app should recommend scope configuration.
