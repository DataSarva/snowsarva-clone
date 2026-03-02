# Research: FinOps - 2026-03-02

**Time:** 01:57 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended baseline for cost attribution is: **object tags** to associate resources/users with logical units (e.g., cost centers) and **query tags** to attribute costs for shared applications that issue queries on behalf of multiple groups. [1]
2. Within a single account, Snowflake documents using `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, and `QUERY_ATTRIBUTION_HISTORY` to attribute warehouse compute credits by tag (warehouse tags, user tags, and query tags, depending on the scenario). [1]
3. `QUERY_ATTRIBUTION_HISTORY` represents **per-query attributed warehouse compute credits** and explicitly **does not include**: storage, data transfer, cloud services, serverless features, or AI token costs; it also does **not** include warehouse idle time in the per-query numbers. [1]
4. Snowflake documents patterns to “include idle time” by allocating warehouse metered credits (`WAREHOUSE_METERING_HISTORY`) proportionally to query-attributed credits by user or query tag (i.e., reconcile to metered credits). [1]
5. Snowflake’s cost exploration guidance emphasizes that org/account cost UIs and cost-related views can be delayed (e.g., up to **72 hours** for cost in Snowsight) and are presented in **UTC**. [3]
6. Snowflake notes that cloud services credits are only billed when daily cloud services consumption exceeds **10%** of daily warehouse usage; to determine what was billed, query `METERING_DAILY_HISTORY`. [2]
7. Independent validation suggests teams should sanity-check `QUERY_ATTRIBUTION_HISTORY` outputs against metered credits and expectations, and may need custom attribution that explicitly models idle time; Greybeam reports limitations (e.g., idle time excluded, exclusions for short queries, delays, and potential anomalies). [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Join point for tag assignments to objects/users; used in Snowflake’s cost attribution examples. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (includes cloud services component associated with warehouse usage per docs). Used as “metered” truth for warehouse credits. [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed warehouse compute credits; excludes idle time and non-warehouse costs. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to compute billed cloud services credits via adjustments; distinguishes consumed vs billed behavior. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Example for org-wide cost in currency; requires org context. [3] |
| `INFORMATION_SCHEMA.QUERY_HISTORY*()` | Table functions | `INFO_SCHEMA` | Fast query history access within last 7 days, dimensioned by session/user/warehouse; useful for near-real-time FinOps triage. [5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag coverage” report + drift alerts**: daily job that reports % of warehouse credits and query credits that are **untagged** by `cost_center` (or other canonical tag), and surfaces top untagged warehouses/users/query_tags.
2. **Two-lane cost attribution dashboard**:
   - Lane A: “Attributed query credits” (from `QUERY_ATTRIBUTION_HISTORY`) by user/query_tag.
   - Lane B: “Reconciled metered credits” (allocate `WAREHOUSE_METERING_HISTORY` back to tags proportionally) to account for idle time. [1]
3. **Cloud-services billing sanity check**: daily report from `METERING_DAILY_HISTORY` showing whether cloud services credits were billed (10% rule) and how large the adjustment was. [2]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL: Cost center attribution by (a) warehouse tags, (b) query tags, and (c) reconciled metered credits

This is a **draft** that covers common FinOps needs:
- warehouse credits by warehouse tag (dedicated-warehouse model)
- query-attributed credits by query tag (shared-app model)
- reconciled (includes idle) credits by query tag by scaling attributed credits to match metered credits

```sql
-- Inputs
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

-- 1) Metered warehouse credits (hourly)
WITH wh_metered AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
),

-- 2) Warehouse -> cost_center tag mapping (object tags)
wh_tags AS (
  SELECT
    object_id              AS warehouse_id,
    object_name            AS warehouse_name,
    tag_database,
    tag_schema,
    tag_name,
    tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_name = 'COST_CENTER'
),

-- A) Dedicated-warehouse model: metered credits attributed by warehouse tag
cost_by_wh_tag AS (
  SELECT
    COALESCE(t.tag_value, 'untagged') AS cost_center,
    SUM(m.credits_used_compute)      AS metered_compute_credits,
    SUM(m.credits_used_cloud_services) AS metered_cloud_services_credits,
    SUM(m.credits_used)              AS metered_total_credits
  FROM wh_metered m
  LEFT JOIN wh_tags t
    ON m.warehouse_id = t.warehouse_id
  GROUP BY 1
),

-- 3) Per-query attributed credits (excludes idle time, excludes non-warehouse costs)
q_attr AS (
  SELECT
    query_id,
    warehouse_id,
    start_time,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    credits_attributed_compute,
    credits_used_query_acceleration
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
),

-- B) Shared-app model: query-attributed credits by query tag (excludes idle)
cost_by_query_tag_ex_idle AS (
  SELECT
    query_tag,
    SUM(credits_attributed_compute) AS attributed_compute_credits,
    SUM(credits_used_query_acceleration) AS qas_credits
  FROM q_attr
  GROUP BY 1
),

-- 4) Reconcile to metered: allocate idle time implicitly by scaling attributed credits
--    to match metered warehouse credits over the same period.
--    (Snowflake provides this pattern in its examples for users/tags.) [1]
wh_metered_sum AS (
  SELECT
    SUM(credits_used_compute) AS metered_compute_credits
  FROM wh_metered
),
q_attr_sum AS (
  SELECT
    SUM(credits_attributed_compute) AS attributed_compute_credits
  FROM q_attr
),

cost_by_query_tag_incl_idle AS (
  SELECT
    q.query_tag,
    -- scale factor = metered / attributed (avoid div0)
    q.attributed_compute_credits
      / NULLIF(s.attributed_compute_credits, 0)
      * m.metered_compute_credits AS reconciled_compute_credits
  FROM cost_by_query_tag_ex_idle q
  CROSS JOIN wh_metered_sum m
  CROSS JOIN q_attr_sum s
)

SELECT
  'warehouse_tag' AS model,
  cost_center     AS dimension,
  metered_compute_credits AS compute_credits,
  metered_cloud_services_credits AS cloud_services_credits,
  metered_total_credits AS total_credits
FROM cost_by_wh_tag

UNION ALL

SELECT
  'query_tag_ex_idle' AS model,
  query_tag          AS dimension,
  attributed_compute_credits AS compute_credits,
  NULL AS cloud_services_credits,
  attributed_compute_credits AS total_credits
FROM cost_by_query_tag_ex_idle

UNION ALL

SELECT
  'query_tag_incl_idle_reconciled' AS model,
  query_tag                       AS dimension,
  reconciled_compute_credits      AS compute_credits,
  NULL AS cloud_services_credits,
  reconciled_compute_credits      AS total_credits
FROM cost_by_query_tag_incl_idle

ORDER BY model, total_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` has known limitations (idle time excluded; potential data delays/exclusions). | Misleading “cost per query” without reconciliation; could misprioritize optimization work. | Always reconcile to `WAREHOUSE_METERING_HISTORY` totals; run spot checks for a few warehouses/hours. [1][4] |
| Cost views/UI are delayed (e.g., Snowsight up to 72h; UTC). | Near-real-time monitoring may look “wrong”. | Use INFO_SCHEMA table functions for immediate investigation and ACCOUNT_USAGE for durable reporting; label freshness in UI. [3][5] |
| Cloud services billed behavior uses daily 10% rule; many views show consumed credits not adjusted for billing. | “Billed” vs “consumed” confusion; finance reconciliation issues. | Use `METERING_DAILY_HISTORY` and present adjustment explicitly. [2] |

## Links & Citations

1. Snowflake Docs — *Attributing cost* (tags + `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, `QUERY_ATTRIBUTION_HISTORY`; notes on exclusions/idle time) — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — *Exploring compute cost* (cloud services 10% billing rule; `METERING_DAILY_HISTORY`; cost-related views list incl. `APPLICATION_DAILY_USAGE_HISTORY`) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake Docs — *Exploring overall cost* (Snowsight delay up to 72h; UTC; org/account overview; `USAGE_IN_CURRENCY_DAILY` example) — https://docs.snowflake.com/en/user-guide/cost-exploring-overall
4. Greybeam blog — *Deep Dive: Snowflake’s Query Cost and Idle Time Attribution* (cautions/limitations + custom idle-time allocation approach) — https://blog.greybeam.ai/snowflake-cost-per-query/
5. Snowflake Docs — `INFORMATION_SCHEMA.QUERY_HISTORY*()` table functions (fast 7-day query history access; RESULT_LIMIT behavior) — https://docs.snowflake.com/en/sql-reference/functions/query_history

## Next Steps / Follow-ups

- Add a second research note focused on **Native App-specific billing/usage views** surfaced in the compute-cost doc (e.g., `APPLICATION_DAILY_USAGE_HISTORY`) and how a Native App can (or cannot) query/visualize them under the NAF privilege model. [2]
- Prototype a “tagging policy kit” for customers: recommended tag taxonomy + SQL checks for missing tags on warehouses/users + guidance for query tagging in shared apps. [1]
- Decide product stance on query-level attribution: offer both “native (ex-idle)” and “reconciled (incl-idle)” views, with clear caveats and reconciliation checks. [1][4]
