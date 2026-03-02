# Research: FinOps - 2026-03-02

**Time:** 10:23 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is to use **object tags** to associate resources/users with cost centers, and **query tags** to attribute individual queries when a shared application runs queries on behalf of multiple cost centers. (Snowflake docs) [1]
2. Within a single account, cost attribution by tag in SQL is done by querying `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`, `...WAREHOUSE_METERING_HISTORY`, and `...QUERY_ATTRIBUTION_HISTORY`. (Snowflake docs) [1]
3. `QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (plus query acceleration credits) and explicitly excludes **warehouse idle time**; view latency can be up to **8 hours**, and very short queries (≈<=100ms) are excluded. (Snowflake docs) [3]
4. Compute cost analysis is available via Snowsight *and* via querying usage views in `ACCOUNT_USAGE` and `ORGANIZATION_USAGE`. Many views report **credits consumed** (not currency); `USAGE_IN_CURRENCY_DAILY` provides currency amounts. (Snowflake docs) [2]
5. Cloud services credits are billed only if daily cloud services consumption exceeds **10%** of daily virtual warehouse usage; to determine billed compute credits, query `METERING_DAILY_HISTORY`. (Snowflake docs) [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Tag assignments for objects (warehouses/users/etc.) used for attribution joins. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse credit usage (incl. cloud services portion attributed to warehouse). Used for warehouse-level and tag-joined showback. [1][2] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query compute credits (excludes idle). Latency up to 8h; short queries excluded. [1][3] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | view | ACCOUNT_USAGE | Daily metering; used to compute billed cloud services adjustment. Mentioned as source of “actually billed” compute credits. [2] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | view | ORG_USAGE | Org-wide warehouse usage for resources not shared by departments (doc says the query is similar). [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | view | ORG_USAGE | Available only in the organization account for org attribution; required for org-level tag joins. [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | view | ORG_USAGE | Converts credits to cost in currency using daily price of a credit. (Org-wide) [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag coverage + “untagged spend” report (compute):** daily job that computes warehouse credits by tag value (`cost_center`, `env`, `team`) with an explicit “untagged” bucket (using `COALESCE(tag_value,'untagged')`). Use this as a compliance dashboard + alert trigger. [1]
2. **Per-query cost explorer with grouping:** surface top `QUERY_PARAMETERIZED_HASH` / `QUERY_HASH` by attributed credits, to identify recurring expensive patterns; provide drill-down to sample query IDs and query tags. [1][3]
3. **Compute “billed vs consumed” reconciliation widget:** show a daily chart of (a) consumed cloud services credits vs (b) billed cloud services credits using `METERING_DAILY_HISTORY` logic; makes “why did we pay?” questions answerable without hand-waving. [2]

## Concrete Artifacts

### SQL Draft: daily cost-attribution fact table (warehouse + per-query, with idle-time aware gap)

Goal: produce a durable, app-ready table for showback/chargeback.

Key design: keep two measures side-by-side:
- `credits_attributed_query_compute` (from `QUERY_ATTRIBUTION_HISTORY`, excludes idle) [3]
- `credits_metered_warehouse_compute` (from `WAREHOUSE_METERING_HISTORY`, includes metered usage at warehouse grain) [1][2]

That gap is exactly what you need to talk about idle-time / overhead explicitly.

```sql
-- Create a normalized, app-friendly daily fact table.
-- NOTE: this is an MVP draft; refine filters/roles/timezones per tenant.

CREATE OR REPLACE TABLE finops.cost_attribution_daily (
  usage_date DATE,
  domain STRING,                 -- 'WAREHOUSE' | 'QUERY'
  object_name STRING,            -- warehouse_name OR query_id (or query_hash)
  tag_name STRING,
  tag_value STRING,

  credits_metered_warehouse_compute NUMBER(38, 9),
  credits_attributed_query_compute  NUMBER(38, 9),
  credits_used_query_acceleration  NUMBER(38, 9),

  source_schema STRING,          -- ACCOUNT_USAGE/ORG_USAGE
  loaded_at TIMESTAMP_LTZ
);

-- 1) Warehouse-level showback by warehouse tag (dedicated-warehouse scenario).
INSERT INTO finops.cost_attribution_daily
SELECT
  TO_DATE(wmh.start_time) AS usage_date,
  'WAREHOUSE' AS domain,
  wmh.warehouse_name AS object_name,
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS credits_metered_warehouse_compute,
  NULL AS credits_attributed_query_compute,
  NULL AS credits_used_query_acceleration,
  'ACCOUNT_USAGE' AS source_schema,
  CURRENT_TIMESTAMP() AS loaded_at
FROM snowflake.account_usage.warehouse_metering_history wmh
LEFT JOIN snowflake.account_usage.tag_references tr
  ON tr.domain = 'WAREHOUSE'
 AND tr.object_id = wmh.warehouse_id
WHERE wmh.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5,9,10;

-- 2) Query-level attribution by query tag (shared-app scenario).
INSERT INTO finops.cost_attribution_daily
SELECT
  TO_DATE(qah.start_time) AS usage_date,
  'QUERY' AS domain,
  qah.query_id AS object_name,
  'QUERY_TAG' AS tag_name,
  COALESCE(NULLIF(qah.query_tag, ''), 'untagged') AS tag_value,
  NULL AS credits_metered_warehouse_compute,
  SUM(qah.credits_attributed_compute) AS credits_attributed_query_compute,
  SUM(qah.credits_used_query_acceleration) AS credits_used_query_acceleration,
  'ACCOUNT_USAGE' AS source_schema,
  CURRENT_TIMESTAMP() AS loaded_at
FROM snowflake.account_usage.query_attribution_history qah
WHERE qah.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5,9,10;

-- Optional sanity check: daily deltas between metered warehouse compute and attributed query compute.
-- This is not “wrong”; it highlights idle-time and non-attributed work.
SELECT
  usage_date,
  SUM(credits_metered_warehouse_compute) AS metered_compute,
  SUM(credits_attributed_query_compute) AS attributed_query_compute,
  metered_compute - attributed_query_compute AS gap_idle_and_overhead
FROM finops.cost_attribution_daily
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY 1
ORDER BY 1 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes warehouse idle time and very short queries; using it alone will understate true warehouse cost. | Misleading “true cost per team/app/query” if users treat it as a reconciled total. | Always pair with `WAREHOUSE_METERING_HISTORY` totals and explicitly compute the “gap”. [1][3] |
| Up to ~8 hours latency for `QUERY_ATTRIBUTION_HISTORY`. | Dashboards/alerts may appear “delayed” vs near-real-time. | Communicate freshness; design jobs with backfill / late-arriving data handling. [3] |
| Org-wide attribution limitations: no organization-wide equivalent of `QUERY_ATTRIBUTION_HISTORY`. | Harder to do org-wide query-level chargeback across accounts. | Provide per-account query attribution; use org-wide only for resources not shared by departments (warehouse tag showback). [1] |
| Tagging compliance is a process problem (not purely a data problem). | Large “untagged” bucket reduces accountability. | Add tag coverage dashboards + policy/process (automation on resource creation). [1] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake Docs — QUERY_ATTRIBUTION_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history

## Next Steps / Follow-ups

- Expand the artifact into an ADR for “Cost Attribution Data Model v1”: define grains (daily/hourly), dimensions (tag sets, account, warehouse), and freshness/backfill strategy.
- Add a second pipeline that computes **tag coverage** metrics (e.g., % of metered credits mapped to a cost_center vs untagged).
- In the next research cycle, rotate to **native-apps**: verify which usage views (e.g., `APPLICATION_DAILY_USAGE_HISTORY`) are best for Native App chargeback and how these should appear inside a Native App’s shared database.
