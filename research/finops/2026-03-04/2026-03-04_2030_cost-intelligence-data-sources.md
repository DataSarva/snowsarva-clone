# Research: FinOps - 2026-03-04

**Time:** 20:30 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost intelligence data sources + attribution primitives)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake exposes daily credit usage and “usage in currency” at the **organization** level via `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`. This is an org-level (multi-account) cost/usage feed intended for daily rollups. [1]
2. Snowflake exposes query-level execution metadata via the account usage `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` view (also in `READER_ACCOUNT_USAGE` for reader accounts). This is a primary primitive for attributing activity by warehouse/user/session/query tags across time ranges. [2]
3. Snowflake exposes hourly warehouse credit consumption via `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, returning hourly credit usage for one or more warehouses. This is a primary primitive for warehouse-level cost rollups and as a basis for query-cost allocation. [3]
4. Snowflake’s “compute cost exploration” guidance frames total compute cost as a combination of **virtual warehouses** and **serverless** features (Snowflake-managed compute). A credible FinOps model must track these separately and then unify them for a full “compute cost” view. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | ORG_USAGE | Daily credit usage + “usage in currency” (org-level). Use for daily $ rollups and cross-account dashboards. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Query-level metadata; key dimensions for allocation (warehouse, user, session, tags, time range). Not a direct $ feed by itself. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by warehouse; foundational for warehouse cost rollups and allocation to queries by time overlap. [3] |
| (Reference hub) `SNOWFLAKE.ORGANIZATION_USAGE` | Schema | ORG_USAGE | Contains additional org-level metering views (useful when building multi-account FinOps). [5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Daily cost spine (credits + currency) per account/region/service type**: build a canonical “daily_cost_fact” table seeded from `ORG_USAGE.USAGE_IN_CURRENCY_DAILY`, with consistent dimensions and late-arriving handling.
2. **Warehouse cost explorer (hourly → daily)**: materialize hourly warehouse credits from `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` into an internal fact table, then expose: top warehouses by credits, idle patterns, and right-sizing suggestions.
3. **Attribution v0 (warehouse → query)**: allocate warehouse hourly credits down to queries using `QUERY_HISTORY` overlap (start/end time) and (optionally) execution time weights; expose per-user/per-role/per-query_tag cost reports.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Warehouse-hourly credits → query-level credit allocation (v0)

**Intent:** Create a first-pass “query_cost_allocations” table by distributing each warehouse-hour credit slice across queries that overlap that hour.

Caveats (explicit):
- This is an **allocation** model, not a Snowflake-billed-per-query truth source.
- Requires careful handling of queries spanning hour boundaries, multi-cluster warehouses, and queueing vs execution time.

```sql
-- v0 allocation model: distribute hourly warehouse credits across overlapping queries
-- Sources:
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY  [3]
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY               [2]
--
-- Parameters to bind in your app layer:
--   :start_ts, :end_ts

WITH wm AS (
  SELECT
    START_TIME                      AS hour_start_ts,
    END_TIME                        AS hour_end_ts,
    WAREHOUSE_ID,
    WAREHOUSE_NAME,
    CREDITS_USED                    AS wh_credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE START_TIME >= :start_ts
    AND END_TIME   <= :end_ts
),
qh AS (
  SELECT
    QUERY_ID,
    WAREHOUSE_ID,
    WAREHOUSE_NAME,
    USER_NAME,
    ROLE_NAME,
    QUERY_TAG,
    START_TIME                      AS query_start_ts,
    END_TIME                        AS query_end_ts,
    DATEDIFF('millisecond', START_TIME, END_TIME) AS query_exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE START_TIME < :end_ts
    AND END_TIME   > :start_ts
    AND WAREHOUSE_ID IS NOT NULL
),
-- join queries to the metering hour slice when they overlap
qh_x_wm AS (
  SELECT
    wm.hour_start_ts,
    wm.hour_end_ts,
    wm.warehouse_id,
    wm.warehouse_name,
    wm.wh_credits_used,
    qh.query_id,
    qh.user_name,
    qh.role_name,
    qh.query_tag,
    -- overlap duration in ms between [query_start, query_end] and [hour_start, hour_end]
    GREATEST(
      0,
      DATEDIFF(
        'millisecond',
        GREATEST(qh.query_start_ts, wm.hour_start_ts),
        LEAST(qh.query_end_ts, wm.hour_end_ts)
      )
    ) AS overlap_ms
  FROM wm
  JOIN qh
    ON qh.warehouse_id = wm.warehouse_id
   AND qh.query_start_ts < wm.hour_end_ts
   AND qh.query_end_ts   > wm.hour_start_ts
),
weights AS (
  SELECT
    hour_start_ts,
    hour_end_ts,
    warehouse_id,
    warehouse_name,
    wh_credits_used,
    query_id,
    user_name,
    role_name,
    query_tag,
    overlap_ms,
    SUM(overlap_ms) OVER (
      PARTITION BY hour_start_ts, warehouse_id
    ) AS total_overlap_ms
  FROM qh_x_wm
)
SELECT
  hour_start_ts,
  hour_end_ts,
  warehouse_id,
  warehouse_name,
  query_id,
  user_name,
  role_name,
  query_tag,
  wh_credits_used,
  overlap_ms,
  total_overlap_ms,
  IFF(total_overlap_ms = 0, NULL, (overlap_ms / total_overlap_ms) * wh_credits_used) AS allocated_query_credits
FROM weights;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `USAGE_IN_CURRENCY_DAILY` granularity/dimensions may not map 1:1 to account-level warehouse/query dimensions. | Currency rollups may not reconcile cleanly with warehouse-level allocations. | Inspect actual columns + sample outputs in a target org; confirm join keys (account locator, region, service type, etc.). [1][5] |
| Query-level cost is not directly billed per query; any per-query “$” is an allocation. | Users may misinterpret as official billing. | UI copy + docs: label as allocation; offer reconciliation reports vs metering totals. [2][3] |
| Latency/retention differences across `ACCOUNT_USAGE` and `ORG_USAGE` views. | Backfills and incremental loads could be incorrect without watermark strategy. | Document view latencies; implement late-arriving update windows; test on multi-day loads. [2][3][5] |
| Serverless compute costs require additional sources beyond warehouse metering. | Under-counting total compute if only warehouse credits are tracked. | Expand sources to serverless metering views referenced by compute cost guidance; add separate fact tables per service category. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
5. https://docs.snowflake.com/en/sql-reference/organization-usage

## Next Steps / Follow-ups

- Pull the actual column lists for `USAGE_IN_CURRENCY_DAILY` and decide the canonical dimension model (account, region, service type, currency) for the Native App’s “daily_cost_fact”.
- Identify the minimal set of additional views needed to cover serverless features (per [4]) so “total compute” is complete.
- Formalize an ADR for “Allocation vs Billing Truth” and how the app communicates reconciliation.
