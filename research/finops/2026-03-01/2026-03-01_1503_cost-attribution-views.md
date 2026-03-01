# Research: FinOps - 2026-03-01

**Time:** 15:03 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach to cost attribution is to use **object tags** (for resources/users) and **query tags** (for per-query attribution when an application runs queries on behalf of multiple cost centers). [1]
2. Within a single account, Snowflake cost attribution in SQL commonly joins **SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES** with **SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** (for warehouse credit usage) and/or **SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** (for per-query attributed credits). [1]
3. **QUERY_ATTRIBUTION_HISTORY exists only at the account level** (ACCOUNT_USAGE); Snowflake explicitly notes there is **no organization-wide equivalent** of QUERY_ATTRIBUTION_HISTORY. [1]
4. **WAREHOUSE_METERING_HISTORY (ACCOUNT_USAGE)** provides hourly warehouse credit usage for the last **365 days**, and includes columns for compute credits, cloud services credits, and credits attributed to compute queries; warehouse **idle time is not included** in CREDITS_ATTRIBUTED_COMPUTE_QUERIES. [4]
5. When reconciling Account Usage WAREHOUSE_METERING_HISTORY with an Organization Usage counterpart, Snowflake notes you must set the session timezone to UTC (ALTER SESSION SET TIMEZONE = UTC). [4]
6. A **resource monitor** can trigger notify/suspend actions for **warehouses**, but Snowflake states resource monitors **do not track serverless features and AI services**; to monitor credit consumption by those, use a **budget** instead. [3]
7. Resource monitor quotas include credits consumed by both warehouses and the cloud services that support them, but resource monitor limits **do not take into account** the daily **10% cloud services adjustment** (Snowflake uses all cloud services credit consumption to evaluate thresholds, even if some is not billed). [3]
8. Snowflake’s “Exploring compute cost” documentation states cloud services usage is billed only if daily cloud services consumption exceeds **10%** of daily virtual warehouse consumption; to determine credits actually billed, query **METERING_DAILY_HISTORY**. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | View | ACCOUNT_USAGE | Identify objects (warehouses/users/etc.) that have tags; used for cost attribution joins. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits by warehouse (up to 365 days). Has compute vs cloud services columns; includes CREDITS_ATTRIBUTED_COMPUTE_QUERIES which excludes idle time. Latency up to 180 min (cloud services column up to 6h). [4] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query compute credits attribution; Snowflake notes no org-wide equivalent. Idle time not included in query cost; can be redistributed separately if desired. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Used to determine billed cloud services via adjustment columns. [2] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | View | ORG_USAGE | Organization-level view exists; timezone alignment considerations when reconciling with ACCOUNT_USAGE. [4] |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | View | ORG_USAGE | Daily credit consumption plus cost in the org’s currency. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution engine v1 (warehouses):** Build a daily “credits by cost_center tag” report by joining TAG_REFERENCES(domain='WAREHOUSE') to WAREHOUSE_METERING_HISTORY; include an “untagged” bucket. (This is directly aligned with Snowflake’s documented approach.) [1]
2. **Idle time awareness:** Add an “idle credits” metric per warehouse per day using (credits_used_compute - credits_attributed_compute_queries) and surface “idle%” as a waste signal. [4]
3. **Governance gap report:** Produce “untagged resources / untagged queries” coverage metrics (e.g., warehouses with NULL tag_value; queries with empty/NULL query_tag) to drive enforcement + automation workflows. [1]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Daily cost-center attribution for warehouses (including idle credits)

Purpose: attribute warehouse compute credits to a warehouse-level tag value, while also surfacing idle credits per warehouse so FinOps can identify waste.

```sql
-- Daily warehouse compute attribution by warehouse tag + idle credits
-- Sources: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- Notes:
--  - WAREHOUSE_METERING_HISTORY is hourly; this rolls up to daily.
--  - CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes idle time; idle_credits is computed as the delta.

WITH hourly AS (
  SELECT
    DATE_TRUNC('DAY', wmh.start_time)               AS usage_date,
    wmh.warehouse_id,
    wmh.warehouse_name,
    wmh.credits_used_compute,
    wmh.credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  WHERE wmh.start_time >= DATEADD('DAY', -30, CURRENT_DATE())
), wh_tags AS (
  SELECT
    tr.object_id AS warehouse_id,
    tr.tag_name,
    tr.tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  WHERE tr.domain = 'WAREHOUSE'
    AND tr.tag_name ILIKE 'COST_CENTER'  -- adjust if using cost_management.tags.cost_center
)
SELECT
  h.usage_date,
  COALESCE(t.tag_value, 'untagged') AS cost_center,
  h.warehouse_name,
  SUM(h.credits_used_compute) AS compute_credits,
  SUM(h.credits_attributed_compute_queries) AS attributed_query_credits,
  ( SUM(h.credits_used_compute) - SUM(h.credits_attributed_compute_queries) ) AS idle_credits,
  IFF(SUM(h.credits_used_compute) = 0,
      NULL,
      ( SUM(h.credits_used_compute) - SUM(h.credits_attributed_compute_queries) ) / SUM(h.credits_used_compute)
  ) AS idle_ratio
FROM hourly h
LEFT JOIN wh_tags t
  ON h.warehouse_id = t.warehouse_id
GROUP BY 1, 2, 3
ORDER BY usage_date DESC, compute_credits DESC;
```

### (Optional next) Query-tag attribution coverage

```sql
-- Quick coverage: how much per-query compute is coming in with an explicit query_tag vs untagged
SELECT
  COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
  SUM(credits_attributed_compute) AS compute_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE())
GROUP BY 1
ORDER BY compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assumption: warehouse tag name is COST_CENTER (or cost_center) and is consistently applied | Attribution results will be misleading and show large “untagged” buckets | Run TAG_REFERENCES coverage queries; compare to expected owned warehouses/users. [1] |
| Using WAREHOUSE_METERING_HISTORY totals as “billed credits” | May not reconcile to invoices because cloud services billing includes a daily 10% adjustment; some views show consumed credits not billed | Use METERING_DAILY_HISTORY to compute billed cloud services and reconcile. [2][3][4] |
| Organization-wide query attribution is expected | Not supported: Snowflake notes there is no org-wide QUERY_ATTRIBUTION_HISTORY equivalent | Limit query-level attribution to account scope; aggregate up externally if needed. [1] |
| Timezone mismatches between ACCOUNT_USAGE vs ORG_USAGE comparisons | Cross-schema reconciliation may look off by hour/day boundaries | Follow Snowflake guidance: set session timezone to UTC when reconciling. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. https://docs.snowflake.com/en/user-guide/resource-monitors
4. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Add a companion note under `governance/` soon: how to automate tag enforcement (e.g., on CREATE WAREHOUSE/USER) and reporting for untagged coverage.
- Extend the artifact into a small “FinOps mart” schema design (daily facts + dimensions for warehouse/user/tag mappings) to support the Native App’s packaged dashboards.
