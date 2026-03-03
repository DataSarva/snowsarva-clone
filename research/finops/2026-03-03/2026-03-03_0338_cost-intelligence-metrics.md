# Research: FinOps - 2026-03-03

**Time:** 03:38 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + budgets + idle-time reconciliation)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost-attribution approach is to use **object tags** to associate resources/users to cost centers and **query tags** to attribute individual queries when applications run queries on behalf of multiple departments. (Snowflake docs) [1]
2. Within an account, cost attribution by tag can be built by joining **SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES** with **WAREHOUSE_METERING_HISTORY** (warehouse credits) and/or using **QUERY_ATTRIBUTION_HISTORY** (per-query compute attribution). (Snowflake docs) [1]
3. **QUERY_ATTRIBUTION_HISTORY** is account-scoped only (no org-wide equivalent), and its per-query attribution explicitly **excludes warehouse idle time** and excludes other cost types (storage, data transfer, cloud services, serverless, AI token costs). (Snowflake docs) [1]
4. Snowflake introduced **tag-based budgets**: a budget can be configured to monitor a specific tag value; when tags change, cost attribution updates within hours and is automatically backfilled for the **entire current month**. (Snowflake engineering blog) [2]
5. Virtual warehouses are billed **per-second with a 60-second minimum each time a warehouse starts/resumes**, and similar 60-second minimum behavior applies when resizing up (incremental credits for the added capacity). (Snowflake docs) [3]
6. Cloud services credits are only charged if daily cloud services usage exceeds **10% of daily warehouse usage**, with the adjustment computed daily in UTC; serverless compute does not factor into that 10% adjustment. (Snowflake docs) [3]

*Third-party operational signals (treat as “needs validation in-customer account”):* Greybeam reports that QUERY_ATTRIBUTION_HISTORY may have quirks such as data freshness delays and exclusion of very short queries, and recommends validating against WAREHOUSE_METERING_HISTORY for reconciliation. (Greybeam blog) [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Warehouse compute credits used (hourly grain). Used as “meter”/reconciliation baseline in Snowflake examples. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query compute attribution; excludes idle time and non-warehouse costs; no org-wide equivalent. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Map objects/users to tag values (domain-specific). Join key differs by domain (e.g., warehouse_id/object_id). [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | view | ORG_USAGE | Org-wide warehouse metering (usable for “dedicated resource” attribution). [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | view | ORG_USAGE | Tag references available only in org account. [1] |
| (Snowsight) Cost Management → Budgets (tag-based budgets) | UI/API-backed | n/a | Budget monitors a tag; updates within hours; backfills current month. [2] |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag coverage” linter & dashboard**: report % of warehouse credits attributable to known tag values vs `untagged` (warehouse-level) + % of query credits attributable to query_tag/user tags (query-level). Uses TAG_REFERENCES + WAREHOUSE_METERING_HISTORY + QUERY_ATTRIBUTION_HISTORY. [1]
2. **Idle-time reconciliation module**: compute (warehouse metered credits) − (sum attributed query credits) per warehouse-hour and allocate idle to cost centers proportionally (or to an explicit “idle” bucket). This bridges Snowflake’s stated exclusion of idle time in per-query attribution. [1]
3. **Budget-to-tags onboarding wizard**: generate the SQL + recommended tag taxonomy (project/cost_center/env) and operational steps to align with Snowflake’s tag-based budgets model (tag inheritance + override precedence). [2]

## Concrete Artifacts

### Artifact: SQL draft — Warehouse-hour compute chargeback with idle-time allocation to query_tag

**Goal:** produce a reconciled chargeback table by hour + `query_tag` that sums to warehouse metering credits.

**Notes:**
- Snowflake states QUERY_ATTRIBUTION_HISTORY excludes idle time. This draft allocates idle proportionally to observed query-tag spend for the same warehouse-hour. [1]
- This draft intentionally keeps an `idle_credits_allocated` component so we can show “true cost” vs “active query cost”.

```sql
-- Reconciled compute chargeback by warehouse-hour and query_tag
-- Inputs:
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (metered credits, hourly)
--   - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (query-attributed credits; excludes idle)
-- Output: warehouse-hour x tag with:
--   - active_query_credits
--   - idle_credits_allocated (proportional)
--   - total_reconciled_credits (= metered)

WITH params AS (
  SELECT
    DATEADD('DAY', -30, CURRENT_TIMESTAMP()) AS start_ts,
    CURRENT_TIMESTAMP() AS end_ts
),

wh_meter AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time AS hour_start,
    credits_used_compute AS metered_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
),

q_attr AS (
  SELECT
    warehouse_id,
    DATE_TRUNC('HOUR', start_time) AS hour_start,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS active_query_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
  GROUP BY 1,2,3
),

-- Total active query credits by warehouse-hour
q_tot AS (
  SELECT
    warehouse_id,
    hour_start,
    SUM(active_query_credits) AS total_active_query_credits
  FROM q_attr
  GROUP BY 1,2
),

-- Join metered with active; compute idle gap
wh_recon AS (
  SELECT
    m.warehouse_id,
    m.warehouse_name,
    m.hour_start,
    m.metered_credits,
    COALESCE(t.total_active_query_credits, 0) AS total_active_query_credits,
    GREATEST(m.metered_credits - COALESCE(t.total_active_query_credits, 0), 0) AS idle_credits
  FROM wh_meter m
  LEFT JOIN q_tot t
    ON m.warehouse_id = t.warehouse_id
   AND m.hour_start   = t.hour_start
),

final AS (
  SELECT
    r.warehouse_id,
    r.warehouse_name,
    r.hour_start,
    a.tag,
    a.active_query_credits,

    -- Allocate idle proportionally to active usage. If no active usage, keep idle in a dedicated bucket.
    CASE
      WHEN r.total_active_query_credits > 0
        THEN r.idle_credits * (a.active_query_credits / r.total_active_query_credits)
      ELSE 0
    END AS idle_credits_allocated,

    CASE
      WHEN r.total_active_query_credits > 0
        THEN a.active_query_credits + (r.idle_credits * (a.active_query_credits / r.total_active_query_credits))
      ELSE a.active_query_credits
    END AS total_reconciled_credits,

    r.metered_credits,
    r.idle_credits
  FROM wh_recon r
  LEFT JOIN q_attr a
    ON r.warehouse_id = a.warehouse_id
   AND r.hour_start   = a.hour_start
)

SELECT *
FROM final
QUALIFY tag IS NOT NULL
ORDER BY hour_start DESC, total_reconciled_credits DESC;
```

### Artifact: ADR (draft) — “Cost Attribution Reconciliation Strategy”

**Context:** Snowflake provides warehouse-level metering (WAREHOUSE_METERING_HISTORY) and per-query attribution (QUERY_ATTRIBUTION_HISTORY) but states per-query attribution excludes idle time and various non-warehouse costs. [1]

**Decision:**
- Treat **WAREHOUSE_METERING_HISTORY** as the reconciliation baseline for warehouse compute.
- Treat **QUERY_ATTRIBUTION_HISTORY** as “active compute” signal.
- Model **idle compute** as a first-class component at warehouse-hour grain:
  - default allocation: proportional to active spend (by query_tag, user tag, or role)
  - optional policy: attribute idle to warehouse owner tag (e.g., `cost_center` on warehouse)
  - optional policy: keep idle in explicit `__IDLE__` bucket for hygiene enforcement.

**Consequences:**
- Enables chargeback that sums exactly to metered compute.
- Makes “idle waste” visible, which is actionable (autosuspend, consolidation, workload isolation).
- Requires clear policy decisions; different orgs will want different idle allocation.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tag-based budgets support / semantics may vary by account edition / rollout | Budget automation features may not be available everywhere | Confirm in target customer accounts + via Snowflake docs once available. Source is engineering blog. [2] |
| Idle-time allocation policy is subjective (proportional vs owner vs explicit idle bucket) | Different “fairness” outcomes for chargeback | Provide configurable policy + show both “active” and “reconciled” views. |
| Query attribution coverage may not include every query pattern (e.g., very short queries) | Gaps between metered and attributed may not be purely idle | Compare recon residuals across periods; validate with Snowflake support if anomalies persist. Greybeam notes potential quirks. [4] |
| Org-wide query attribution is unavailable | Can’t do per-query cost rollups across accounts centrally | Use ORG_USAGE for dedicated resources and per-account pipelines for query-level details. [1] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Engineering Blog — Tag-based budgets: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/
3. Snowflake Docs — Understanding compute cost: https://docs.snowflake.com/en/user-guide/cost-understanding-compute
4. Greybeam — Query cost & idle attribution deep dive: https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a “tag coverage” report design (tables + UI mock) to the FinOps app backlog.
- Decide default idle allocation policy for the app (and make it configurable).
- Research: Snowflake budgets APIs (ADD_TAG, budget object DDL) to automate budget creation and export budget telemetry into the app.
