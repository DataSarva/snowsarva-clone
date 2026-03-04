# Research: FinOps - 2026-03-04

**Time:** 12:01 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + idle time + Native App usage views)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach to cost attribution is to use **object tags** to associate resources/users with departments/projects, and **query tags** when a shared application issues queries on behalf of multiple departments.  
   Source: Snowflake “Attributing cost” guide. https://docs.snowflake.com/en/user-guide/cost-attributing
2. Within a single account, you can attribute warehouse costs by joining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` to `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (for warehouse-tagging scenarios), and/or joining `TAG_REFERENCES` to `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (for user-tagging or query-tagging scenarios).  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; the latter **excludes warehouse idle time**. Idle cost for a window can be computed as the difference of those sums.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. `QUERY_ATTRIBUTION_HISTORY` provides per-query warehouse compute attribution; Snowflake documentation states per-query cost attribution does **not** include idle time (and does not include non-warehouse costs such as storage, data transfer, serverless features, etc.).  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing
5. Snowflake’s “Exploring compute cost” guide calls out that cloud services credits are only billed if daily cloud services consumption exceeds 10% of daily virtual warehouse usage, and recommends `METERING_DAILY_HISTORY` to determine billed credits.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
6. Snowflake’s “Exploring compute cost” guide lists `APPLICATION_DAILY_USAGE_HISTORY` as a feature-specific view that provides **daily credit usage for Snowflake Native Apps** in an account within the last 365 days.  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to objects/users. Join keys differ by domain (e.g., warehouses via `object_id`). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (up to last 365 days). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to help derive idle cost. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed warehouse compute; excludes idle + other cost classes (per docs). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily metering; used to compute billed cloud services credits (per compute-cost docs). |
| `SNOWFLAKE.ACCOUNT_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ACCOUNT_USAGE` / `ORG_USAGE` | Converts daily credits to currency using daily credit price (per compute-cost docs). |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Daily credit usage for Snowflake Native Apps (per compute-cost docs). |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide warehouse metering exists; docs note some attribution views (e.g., `QUERY_ATTRIBUTION_HISTORY`) do not have org-wide equivalents. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Attribution coverage” report**: % of warehouse credits that are (a) attributable to queries vs idle, and (b) attributable to a cost center (tagged) vs “untagged”, with drilldowns by warehouse and day.
2. **Native App usage lens**: incorporate `APPLICATION_DAILY_USAGE_HISTORY` into the app’s FinOps dashboard to isolate spend caused by Native Apps vs other workloads (account-local), and reconcile against overall metering.
3. **Chargeback table builder**: a scheduled transformation that produces a daily `COST_CENTER` ledger allocating (i) query-attributed credits by query_tag/user_tag and (ii) idle credits pro-rata to the same dimension (tag/user/query_tag), matching Snowflake’s documented approach.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Daily warehouse credits by cost_center tag + explicit idle-time line item

Goal: produce a daily table with (a) total warehouse compute credits and (b) idle credits derived from `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`.

```sql
-- Assumes warehouses are tagged with COST_MANAGEMENT.TAGS.COST_CENTER
-- Sources:
--  - Cost attribution join patterns: https://docs.snowflake.com/en/user-guide/cost-attributing
--  - Idle time derivation fields: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

SET start_date = DATEADD('day', -30, CURRENT_DATE());

WITH wh AS (
  SELECT
      TO_DATE(wmh.start_time)                         AS usage_date,
      wmh.warehouse_id,
      wmh.warehouse_name,
      SUM(wmh.credits_used_compute)                   AS credits_used_compute,
      SUM(wmh.credits_attributed_compute_queries)     AS credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  WHERE wmh.start_time >= $start_date
    AND wmh.warehouse_id > 0 -- skip pseudo warehouses like CLOUD_SERVICES_ONLY (per compute-cost docs)
  GROUP BY 1,2,3
),

wh_with_tags AS (
  SELECT
      wh.*,
      COALESCE(tr.tag_value, 'untagged') AS cost_center
  FROM wh
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
    ON tr.domain = 'WAREHOUSE'
   AND tr.object_id = wh.warehouse_id
   AND tr.tag_name = 'COST_CENTER'
)

SELECT
    usage_date,
    warehouse_name,
    cost_center,
    credits_used_compute,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute
FROM wh_with_tags
ORDER BY usage_date DESC, credits_used_compute DESC;
```

### SQL draft: Allocate idle credits pro-rata to query_tag (showback-friendly)

Rationale: Snowflake documents that per-query attribution excludes idle time, but also provides an example approach to distribute idle time proportional to usage for reconciliation.  
Source: https://docs.snowflake.com/en/user-guide/cost-attributing

```sql
-- Allocate monthly idle credits to QUERY_TAG proportionally by attributed query credits.
-- This follows the pattern shown in Snowflake docs under "Calculating the cost of queries (including idle time) by query tag".
-- Source: https://docs.snowflake.com/en/user-guide/cost-attributing

WITH wh_bill AS (
  SELECT SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
    AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
),

tag_credits AS (
  SELECT
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute)            AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
    AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
  GROUP BY 1
),

total_credit AS (
  SELECT SUM(credits) AS sum_all_credits
  FROM tag_credits
)

SELECT
    tc.tag,
    tc.credits / NULLIF(t.sum_all_credits, 0) * w.compute_credits AS attributed_credits_including_idle
FROM tag_credits tc
CROSS JOIN total_credit t
CROSS JOIN wh_bill w
ORDER BY attributed_credits_including_idle DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tag naming/casing varies across orgs (e.g., `COST_CENTER` vs `cost_center`), and tag database/schema may not be `COST_MANAGEMENT.TAGS`. | Queries may return mostly `untagged` or miss tags entirely. | Detect tag names from `TAG_REFERENCES` and configure via app settings. |
| Org-wide attribution differs from account-level attribution (e.g., docs state `QUERY_ATTRIBUTION_HISTORY` has no org-wide equivalent). | A “single pane of glass” across accounts may require different modeling or per-account ingestion. | Confirm available `ORGANIZATION_USAGE` views + privileges in target customer org. |
| Credits consumed != credits billed for cloud services due to daily adjustment rule (10% threshold). | Chargeback models may not reconcile to invoices if using raw consumption. | Use `METERING_DAILY_HISTORY` for billed cloud services logic (per docs). |
| `APPLICATION_DAILY_USAGE_HISTORY` granularity and dimensions may not map cleanly to internal cost centers. | Native App cost separation may be partial or require correlation with query tags/warehouses. | Inspect columns in the view and test against sample account data. |

## Links & Citations

1. Snowflake docs: Attributing cost (object tags + query tags, and example SQL patterns) — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: `WAREHOUSE_METERING_HISTORY` view (idle time derivation, timezone note, latency) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake docs: Exploring compute cost (cloud services billing note, `METERING_DAILY_HISTORY`, and `APPLICATION_DAILY_USAGE_HISTORY`) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Snowflake docs: `WAREHOUSE_METERING_HISTORY` table function (6-month window + note to prefer `ACCOUNT_USAGE` for completeness) — https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
5. Snowflake Builders (Medium): Granular cost attribution and chargeback for warehouse costs (examples; references per-query attribution feature) — https://medium.com/snowflake/granular-cost-attribution-and-chargeback-for-warehouse-costs-on-snowflake-cf96fb690967

## Next Steps / Follow-ups

- Pull columns for `APPLICATION_DAILY_USAGE_HISTORY` (and any related app-usage views) into a schema proposal for the Native App’s “App-driven cost” dashboard.
- Draft a small ADR: “Attribution-first data mart” with (a) tag normalization, (b) idle allocation strategy, (c) reconciliation strategy (credits vs currency).
- Add a quick “tag hygiene” widget: list top spend warehouses/users/queries that are `untagged`.
