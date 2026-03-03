# Research: FinOps - 2026-03-03

**Time:** 12:23 UTC  
**Topic:** Cost attribution via object/query tags + budgets (what we can productize in the FinOps Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for cost attribution is: **object tags** for associating resources/users to cost centers, and **query tags** for attributing queries when an application runs on behalf of multiple cost centers. (Snowflake Docs: “Attributing cost”) [1]
2. For SQL-based cost attribution inside an account, Snowflake explicitly calls out using **ACCOUNT_USAGE.TAG_REFERENCES** joined to **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** (warehouse credits) and **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** (query-attributed credits). [1]
3. **QUERY_ATTRIBUTION_HISTORY** “cost per query” excludes several cost components (storage, cloud services, serverless, etc.) and **does not include warehouse idle time**; Snowflake provides examples for distributing idle time separately. [1]
4. **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** provides hourly credit usage per warehouse for the last year, with typical latency up to ~3 hours (cloud services up to ~6 hours). It also provides **CREDITS_ATTRIBUTED_COMPUTE_QUERIES**, which excludes idle. [2]
5. Snowflake introduced **tag-based budgets** (GA per Snowflake engineering blog) where a budget can monitor a tag value (e.g., `project='phoenix'`) rather than a manually curated object list; tag inheritance matters for capturing serverless + nested objects. [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | View | ACCOUNT_USAGE | Identifies objects that have tags; join key varies by domain/object type. Mentioned as primary join source for cost attribution. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly warehouse credit usage (1 year). Includes compute + cloud services columns; idle time can be derived. [1][2] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query attributed compute credits; excludes idle and non-query charges; useful for showback by user/query_tag. [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | View | ORG_USAGE | Available **only in org account**; used for org-wide attribution for resources “exclusively used” by a department; no org-wide QUERY_ATTRIBUTION_HISTORY equivalent. [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | View | ORG_USAGE | Usable from org account for org-wide warehouse metering joins; reconcile requires UTC timezone setting when comparing to ACCOUNT_USAGE. [1][2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost by Tag” materialized attribution table**: scheduled pipeline that produces daily/hourly cost by (tag_name, tag_value, domain, object) using TAG_REFERENCES + WAREHOUSE_METERING_HISTORY; supports “untagged” reporting as a first-class dimension.
2. **Idle-cost allocator**: compute per-warehouse idle credits (compute_credits - attributed_query_credits) and allocate to cost centers based on proportional query-attributed usage (or proportional warehouse usage), matching Snowflake’s documented examples.
3. **Budget guardrails integration**: expose “tag-based budgets readiness” (tag coverage + inheritance) and optionally generate recommended budgets (and alert thresholds) aligned to cost-center / project tags.

## Concrete Artifacts

### SQL Draft: Daily compute credits by cost_center tag (warehouse-dedicated model)

This implements Snowflake’s “resources not shared by departments” pattern: join warehouse metering to TAG_REFERENCES (domain=WAREHOUSE) and aggregate credits by tag.

```sql
-- Cost attribution: dedicated warehouses tagged to a single cost center
-- Source pattern: Snowflake docs “Attributing cost” (Resources not shared by departments)
-- https://docs.snowflake.com/en/user-guide/cost-attributing

WITH wmh AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time::date AS usage_date,
    SUM(credits_used_compute) AS credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
    AND start_time <  CURRENT_DATE()
  GROUP BY 1,2,3
), wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    tag_name,
    COALESCE(tag_value, 'untagged') AS tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
)
SELECT
  t.tag_name,
  t.tag_value,
  w.usage_date,
  SUM(w.credits_used_compute) AS total_compute_credits
FROM wmh w
LEFT JOIN wh_tags t
  ON w.warehouse_id = t.warehouse_id
GROUP BY 1,2,3
ORDER BY usage_date DESC, total_compute_credits DESC;
```

### SQL Draft: Idle cost per warehouse (10-day window)

This is directly aligned to Snowflake’s WAREHOUSE_METERING_HISTORY documentation example.

```sql
-- Idle compute credits per warehouse
-- https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

SELECT
  warehouse_name,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_compute_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY idle_compute_credits DESC;
```

### ADR (Draft): First-class “Attribution Model” modes

**Status:** Draft

**Context**
- Snowflake provides two primary attribution strategies: (a) warehouse/resource ownership via object tags, and (b) per-query attribution via QUERY_ATTRIBUTION_HISTORY + user/query tags. [1]
- QUERY_ATTRIBUTION_HISTORY excludes warehouse idle time and several non-query cost components. [1]

**Decision**
Implement two attribution modes in the FinOps Native App:
1) **Dedicated-resource mode**: attribute warehouse compute by warehouse tag(s). Best when warehouses are not shared.
2) **Shared-resource mode**: attribute compute by user tags and/or query tags using QUERY_ATTRIBUTION_HISTORY; optionally add an **idle allocator** to distribute idle credits proportionally.

**Consequences**
- We must clearly label what is covered (query compute) vs not covered (storage, serverless, etc.) to avoid false precision.
- We should surface “tag coverage” and “untagged” as governance KPIs.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| TAG_REFERENCES join keys can differ by domain/object type; some examples join on warehouse_id/object_id, others use object_name for users. | Wrong joins → misattribution. | Validate with small sample joins per domain (WAREHOUSE vs USER) in a test account. Cross-check against Snowsight tag filtering. [1] |
| Query attribution covers compute cost for query execution but excludes other charge classes (storage, serverless, etc.). | Users may expect “total spend” but see partial. | Explicit UX copy + include other cost sources later; start with compute attribution as “v1”. [1] |
| Org-wide query attribution is not available (no org-wide QUERY_ATTRIBUTION_HISTORY). | Limited cross-account attribution granularity. | Document limitation; use ORG_USAGE for dedicated resources, and per-account pipelines for query attribution. [1] |
| ACCOUNT_USAGE data latency (hours) can affect “near-real-time” dashboards. | Perceived staleness. | Use “data freshness” indicator per dataset; optionally also use INFORMATION_SCHEMA table functions for shorter windows if needed (not covered in sources here). [2] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — WAREHOUSE_METERING_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake Engineering Blog — Tag-based budgets / cost attribution: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Next Steps / Follow-ups

- Pull Snowflake docs for **BUDGET** / tag-based budgets SQL objects + privileges (ADD_TAG API mentioned in blog) to see what a Native App can safely automate vs only recommend. [3]
- Spec the app’s canonical “attribution_fact” table schema (hourly grain, domain, object_id, tag dimensions, method, freshness).
- Add a “tag coverage & drift” report: % of warehouse credits from untagged warehouses/users/query_tag=''. (docs show 'untagged' grouping) [1]
