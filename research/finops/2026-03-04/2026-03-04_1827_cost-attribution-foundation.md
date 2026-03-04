# Research: FinOps - 2026-03-04

**Time:** 18:27 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Cost Attribution Foundation for Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended pattern for cost attribution is to use **object tags** to associate resources/users with cost centers and **query tags** to attribute queries when applications submit work on behalf of multiple cost centers. [1]
2. For account-level attribution, Snowflake explicitly recommends combining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (warehouse credits) and `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute credits). [1]
3. `QUERY_ATTRIBUTION_HISTORY` exists **only at account scope** (ACCOUNT_USAGE). Snowflake notes there is **no organization-wide equivalent** of query-level attribution. [1]
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides hourly credit usage for the account with a `SERVICE_TYPE` column spanning warehouses and many serverless categories (e.g., `SNOWPIPE_STREAMING`, `SNOWPARK_CONTAINER_SERVICES`, `AI_SERVICES`). [3]
5. Snowflake’s compute-cost UI + most credit-consumption views show credits **consumed**, and Snowflake notes that cloud services credits are **billed only if** daily cloud services consumption exceeds **10%** of daily warehouse usage; they recommend `METERING_DAILY_HISTORY` to determine actual billed credits for compute. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tag ↔ object. Used to join tags to warehouses/users/etc. (Latency noted in Account Usage docs; tagging strategy described in cost attribution guide.) [1][4] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse; used for billed warehouse consumption baselines and for distributing idle to cost centers. [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed compute credits; excludes idle time by definition; used to allocate shared warehouse usage to users/query tags. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by service type across warehouses + serverless + cloud services; used for broad breakdown and to monitor non-warehouse categories. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily metering; Snowflake recommends it to determine billed cloud services adjustments. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` counterparts | Views | `ORGANIZATION_USAGE` | Org-wide aggregation exists for many metering views, but Snowflake states no org-wide `QUERY_ATTRIBUTION_HISTORY`. [1][2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution “Truth Table” builder (daily):** materialize a normalized table that allocates *billed* warehouse credits to `QUERY_TAG` (or user-tag / warehouse-tag) by reconciling `WAREHOUSE_METERING_HISTORY` vs `QUERY_ATTRIBUTION_HISTORY` (idle distribution). This becomes the stable backbone for a FinOps Native App semantic layer.
2. **Tag coverage & hygiene dashboard:** detect untagged warehouses/users (and optionally missing mandatory tags) by diffing inventory vs `TAG_REFERENCES`, then surface “% spend unattributed” and “top unattributed warehouses/users”.
3. **Non-warehouse compute guardrails:** use `METERING_HISTORY.SERVICE_TYPE` to trend and alert on serverless/AI categories (e.g., `AI_SERVICES`, `SNOWPIPE_STREAMING`, `SNOWPARK_CONTAINER_SERVICES`) that aren’t governed by warehouse resource monitors.

## Concrete Artifacts

### SQL Draft: Allocate billed warehouse credits to QUERY_TAG (including idle)

Goal: create an attribution result that *adds back idle time* (warehouse metering credits that are not present in `QUERY_ATTRIBUTION_HISTORY`) by allocating idle proportionally to `QUERY_TAG` usage.

Assumptions are called out inline.

```sql
-- COST ATTRIBUTION: billed warehouse credits -> QUERY_TAG (including idle)
--
-- Key idea from Snowflake: QUERY_ATTRIBUTION_HISTORY provides per-query credits
-- but does not include warehouse idle time. [1]
-- So we:
--   (1) compute total billed warehouse credits from WAREHOUSE_METERING_HISTORY
--   (2) compute total attributed per-query credits from QUERY_ATTRIBUTION_HISTORY
--   (3) compute idle = billed - attributed
--   (4) allocate idle across query tags in proportion to attributed credits
--
-- NOTE: This allocates ONLY warehouse metering credits (compute).
-- It does not allocate other service types (e.g., AI_SERVICES, serverless).
--
-- Time window: last full calendar month.

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS end_ts
),

-- 1) Warehouse billed credits over the window
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS wh_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, params
  WHERE start_time >= params.start_ts
    AND start_time <  params.end_ts
),

-- 2) Per-query attributed credits by query_tag
-- Snowflake recommends COALESCE/NULLIF to treat blank tags as 'untagged'. [1]
qtag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_norm,
    SUM(credits_attributed_compute)           AS qtag_attrib_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, params
  WHERE start_time >= params.start_ts
    AND start_time <  params.end_ts
  GROUP BY 1
),

totals AS (
  SELECT
    (SELECT wh_compute_credits FROM wh_bill)                 AS wh_compute_credits,
    (SELECT SUM(qtag_attrib_credits) FROM qtag_credits)      AS total_attrib_credits
),

-- 3) Allocate idle proportionally
alloc AS (
  SELECT
    q.query_tag_norm,
    q.qtag_attrib_credits,
    t.wh_compute_credits,
    t.total_attrib_credits,
    GREATEST(t.wh_compute_credits - t.total_attrib_credits, 0) AS idle_credits,
    CASE
      WHEN t.total_attrib_credits = 0 THEN 0
      ELSE (q.qtag_attrib_credits / t.total_attrib_credits) * (t.wh_compute_credits - t.total_attrib_credits)
    END AS idle_allocated_to_tag
  FROM qtag_credits q
  CROSS JOIN totals t
)

SELECT
  query_tag_norm                              AS query_tag,
  qtag_attrib_credits                         AS attributed_credits_ex_idle,
  idle_allocated_to_tag,
  (qtag_attrib_credits + idle_allocated_to_tag) AS attributed_credits_including_idle,
  wh_compute_credits                          AS total_wh_compute_credits_window
FROM alloc
ORDER BY attributed_credits_including_idle DESC;
```

### Optional extension: Persist as a semantic fact table

Pseudocode-level schema (Native App can materialize into app-owned schema):

```text
FACT_COST_ATTRIBUTION_DAILY
- usage_date (DATE)
- attribution_scope (STRING)  -- e.g., 'QUERY_TAG', 'USER_TAG', 'WAREHOUSE_TAG'
- attribution_key (STRING)    -- e.g., 'COST_CENTER=finance' or 'engineering'
- credits_billed_wh (NUMBER)
- credits_attributed_queries (NUMBER)
- credits_idle_allocated (NUMBER)
- credits_total_allocated (NUMBER)
- credits_non_wh_service (VARIANT)  -- optional: breakdown by service_type from METERING_HISTORY
- source_account_locator (STRING)
- computed_at (TIMESTAMP_LTZ)
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Idle allocation proportional to `QUERY_ATTRIBUTION_HISTORY` is “fair enough” for showback/chargeback. | Attribution may be disputed for bursty workloads or “always-on” shared warehouses. | Validate with stakeholders; compare vs alternative allocations (e.g., per-user, per-warehouse tag, per-time-slice). |
| `QUERY_ATTRIBUTION_HISTORY` is not available org-wide. | Multi-account org rollups must use a different approach (e.g., per-account materialization + federation). | Snowflake explicitly states there is no org-wide equivalent. [1] |
| Credits “consumed” vs “billed” differ due to cloud services adjustment threshold. | Currency forecasts and “true bill” reconciliation can be off if we use the wrong view. | Snowflake recommends `METERING_DAILY_HISTORY` for billed compute credits determination. [2] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake Docs — `METERING_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Snowflake Docs — Account Usage overview: https://docs.snowflake.com/en/sql-reference/account-usage
5. Snowflake Well-Architected Framework (Cost Optimization & FinOps): https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Turn the SQL draft into a reusable dbt model / Snowflake task-driven pipeline that populates `FACT_COST_ATTRIBUTION_DAILY` per account.
- Add a second allocation path: **USER-tag-based** attribution for shared warehouses (join `TAG_REFERENCES` on domain=USER to `QUERY_ATTRIBUTION_HISTORY.user_name`).
- Add a “non-warehouse metering” breakdown module using `METERING_HISTORY` by `SERVICE_TYPE` to make serverless/AI costs first-class.
