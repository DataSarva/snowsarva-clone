# Research: FinOps - 2026-03-02

**Time:** 06:08 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + budgets + resource monitors)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: use **object tags** to associate resources/users with cost centers, and use **query tags** to attribute queries when an application runs queries on behalf of multiple cost centers. (Snowflake docs) [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) for queries run on warehouses in the last **365 days**, but it **excludes warehouse idle time** and other non-warehouse costs (storage, cloud services, serverless features, AI tokens). Latency can be **up to 8 hours**; very short-running queries (≈<=100ms) are not included. (Snowflake docs) [2]
3. **Resource monitors** are for **warehouses only** (user-managed virtual warehouses). They can notify/suspend warehouses when a credit quota threshold is reached, but they cannot track or control serverless features/AI services; Snowflake recommends using **Budgets** for those. (Snowflake docs) [4]
4. **Budgets** define a **monthly** spending limit (in credits) for an account budget or custom budgets over supported object groups, and can deliver notifications via **email**, **cloud queues** (SNS/Event Grid/PubSub), or **webhooks**. Default refresh/latency is up to **6.5 hours**; can be reduced to **1 hour** (low latency budgets) at ~**12x** the compute cost of budgets. (Snowflake docs) [3]
5. Budgets support **user-defined actions** that can call user-defined stored procedures at thresholds or cycle start, enabling automated actions like suspending warehouses, sending notifications, or logging. (Snowflake docs) [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to map tags (e.g., cost_center) to objects/users for attribution. Mentioned in Snowflake cost attribution guidance. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Warehouse credit usage (warehouse-level total; includes idle time at warehouse level). Used for attribution joins. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits attributed; excludes idle time and other costs; 365-day window; up to 8h latency. [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | `ACCOUNT_USAGE` | Metadata about resource monitors (discovered via Resource Monitors docs + ref view page in search results). [4] *(Confirm view columns separately.)* |
| Budgets (`BUDGET` class + related roles) | Feature/API | Cost Mgmt | Budget objects support notifications + user-defined actions; supports more service types than resource monitors. [3] |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` (e.g., metering history + tag references) | Views | `ORGANIZATION_USAGE` | Org-wide attribution is possible for some views; Snowflake notes no org-wide equivalent for `QUERY_ATTRIBUTION_HISTORY`. [1][5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution “coverage” report (tag hygiene):** daily job that computes % of credits that are `untagged` (warehouse tags and/or user tags), plus top untagged warehouses/users; produce a prioritized “tag these 10 things” list. Uses `TAG_REFERENCES` + `WAREHOUSE_METERING_HISTORY` + `QUERY_ATTRIBUTION_HISTORY`. [1][2]
2. **Budget webhook ingest → FinOps event stream:** provide a lightweight endpoint (Native App service) to receive Snowflake Budget webhook alerts and persist them (table) + trigger downstream workflows (Slack/PagerDuty). This directly leverages the “webhook for third-party system” support. [3]
3. **Guardrail templates:** generate recommended resource monitor patterns (90% suspend, 100% suspend_immediate, etc.) and “budgets vs resource monitors” decision prompts, since resource monitors don’t cover serverless/AI services. [4][3]

## Concrete Artifacts

### SQL draft: monthly compute attribution by cost_center (warehouse tags + user/query attribution)

Goal: produce one monthly table/view that can answer: “How many compute credits did each cost center spend, and what share is untagged?”

Notes:
- This uses the **recommended Snowflake approach**: object tags on warehouses/users + query tags when needed. [1]
- Per-query attribution excludes idle time; if you need to distribute idle, use the approach Snowflake shows with `WAREHOUSE_METERING_HISTORY` and proportional allocation. [1][2]

```sql
-- Assumptions:
-- 1) You have a tag named COST_CENTER (or similar) applied to WAREHOUSE and/or USER objects.
-- 2) You want a single-month rollup (last full month here; adjust as needed).
-- 3) You want to attribute per-query compute credits (excluding idle time) via QUERY_ATTRIBUTION_HISTORY.

-- --------------
-- A) Warehouse-level monthly compute credits by warehouse tag (includes idle implicitly because it's total warehouse credits)
-- --------------
WITH month_window AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS month_start,
    DATE_TRUNC('MONTH', CURRENT_DATE())                  AS month_end
),
warehouse_credits AS (
  SELECT
    wmh.warehouse_id,
    SUM(wmh.credits_used_compute) AS credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  JOIN month_window mw
    ON wmh.start_time >= mw.month_start
   AND wmh.start_time <  mw.month_end
  GROUP BY 1
),
warehouse_cost_center AS (
  SELECT
    tr.object_id AS warehouse_id,
    COALESCE(NULLIF(tr.tag_value, ''), 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  WHERE tr.domain = 'WAREHOUSE'
    AND UPPER(tr.tag_name) = 'COST_CENTER'
),
warehouse_rollup AS (
  SELECT
    wcc.cost_center,
    SUM(wc.credits_used_compute) AS warehouse_compute_credits
  FROM warehouse_credits wc
  LEFT JOIN warehouse_cost_center wcc
    ON wc.warehouse_id = wcc.warehouse_id
  GROUP BY 1
),

-- --------------
-- B) Query-level monthly compute credits by USER tag (excludes warehouse idle time)
-- --------------
user_cost_center AS (
  SELECT
    tr.object_name AS user_name,
    COALESCE(NULLIF(tr.tag_value, ''), 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  WHERE tr.domain = 'USER'
    AND UPPER(tr.tag_name) = 'COST_CENTER'
),
query_rollup AS (
  SELECT
    COALESCE(ucc.cost_center, 'untagged') AS cost_center,
    SUM(qah.credits_attributed_compute)  AS query_attributed_compute_credits,
    SUM(qah.credits_used_query_acceleration) AS query_acceleration_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  JOIN month_window mw
    ON qah.start_time >= mw.month_start
   AND qah.start_time <  mw.month_end
  LEFT JOIN user_cost_center ucc
    ON qah.user_name = ucc.user_name
  GROUP BY 1
)

SELECT
  COALESCE(q.cost_center, w.cost_center) AS cost_center,
  q.query_attributed_compute_credits,
  q.query_acceleration_credits,
  w.warehouse_compute_credits
FROM query_rollup q
FULL OUTER JOIN warehouse_rollup w
  ON q.cost_center = w.cost_center
ORDER BY 1;
```

Why two rollups?
- `WAREHOUSE_METERING_HISTORY` gives **total warehouse compute credits** (warehouse-level, includes idle time effects).
- `QUERY_ATTRIBUTION_HISTORY` gives **per-query compute credits** (excludes idle time) and includes **query acceleration credits** field. [2]

This lets the app show:
- “Warehouse total vs query-attributed” gap as an **idle-time / overhead indicator** (not exact, but actionable).
- “Untagged credits” as a first-class KPI for FinOps governance.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming tag name = `COST_CENTER` and present on WAREHOUSE/USER | Queries may return mostly `untagged` or miss mapping | Confirm tag naming conventions; query `TAG_REFERENCES` distinct `tag_name`/`domain`. [1] |
| Using `QUERY_ATTRIBUTION_HISTORY` for “total cost” | Understates total because it excludes idle time + many cost categories (serverless, storage, AI tokens, cloud services) | Explicitly label as “per-query compute on warehouses”; add separate components later using other metering sources. [1][2] |
| Budget notifications/webhooks assumed available in target accounts | Feature/privilege gaps could block automation | Validate required roles/privileges and budget activation path in target environments. [3] |
| Data latency (up to ~8 hours) | Dashboards/alerts may lag | Product UX should communicate “data freshness”; consider budgets low-latency tier with cost tradeoff. [2][3] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Budgets (Monitor credit usage with budgets): https://docs.snowflake.com/en/user-guide/budgets
4. Snowflake Docs — Resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
5. Snowflake Docs — Organization Usage schema: https://docs.snowflake.com/en/sql-reference/organization-usage

## Next Steps / Follow-ups

- Deepen on: which views best cover *non-warehouse* spend components (serverless features, AI services, cloud services adjustments) and how to attribute them by tag/budget object group. (Follow-up topic: `governance` or `observability`.)
- Add a second artifact: “Budget webhook payload schema → ingestion table” once we pull Snowflake’s webhook payload format from docs (separate extract).
