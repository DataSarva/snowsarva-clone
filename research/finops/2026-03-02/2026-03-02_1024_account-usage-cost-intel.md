# Research: FinOps - 2026-03-02

**Time:** 10:24 UTC  
**Topic:** Snowflake FinOps Cost Optimization (query-level compute cost attribution + idle-time reconciliation)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) but **explicitly excludes warehouse idle time**, and may have up to ~8 hours latency; very short queries (≈<=100ms) are excluded. (Snowflake docs)  
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` contains rich per-query metadata (e.g., `QUERY_TAG`, `WAREHOUSE_ID`, timings such as `COMPILATION_TIME`, `QUEUED_*`, `EXECUTION_TIME`) and supports a 365-day window; latency can be up to ~45 minutes. (Snowflake docs)
3. Snowflake’s cost docs recommend using **tags** (object tags and query tags) to attribute spend to logical cost centers; and they call out that many ACCOUNT_USAGE/ORG_USAGE views are “credits consumed”, while “billed” cloud services requires `METERING_DAILY_HISTORY` due to the 10% daily adjustment rule. (Snowflake docs)
4. Third-party practitioners have observed potential discrepancies when reconciling `QUERY_ATTRIBUTION_HISTORY` against metered warehouse credits (e.g., attribution seeming “too high” for short runtimes); they recommend validating against `WAREHOUSE_METERING_HISTORY` and considering custom attribution logic when accuracy matters. (Greybeam blog)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits attributed; excludes idle; short queries excluded; ~8h latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata incl. warehouse + timings + `QUERY_TAG`; 365d window; ~45m latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly metered credits by warehouse; good “bill reconciliation” anchor for warehouse compute. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to compute *billed* cloud services after daily 10% adjustment. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Query Cost (Attribution vs Metered)” reconciliation report**: show attributed per-query credits from `QUERY_ATTRIBUTION_HISTORY` alongside metered `WAREHOUSE_METERING_HISTORY` credits and compute “idle/unattributed remainder” per warehouse-hour.
2. **Chargeback models as pluggable policies**: allow different allocation policies for the idle/unattributed remainder (e.g., proportional to attributed credits per query tag; proportional to execution time per query; or assigned to “idle bucket”).
3. **Anomaly checks for attribution quality**: flag warehouse-hours where `SUM(CREDITS_ATTRIBUTED_COMPUTE)` is unexpectedly close to or exceeds metered credits, or where `warehouse_id` mismatches between attribution and query history (per observed practitioner issues).

## Concrete Artifacts

### SQL draft: build a reconciled `warehouse_hour` + `query_hour` fact model

Goal: produce two materializable datasets:
- `FINOPS.WAREHOUSE_HOUR_COST` (metered vs attributed vs idle remainder by warehouse-hour)
- `FINOPS.QUERY_HOUR_COST` (query-level cost with optional idle allocation policy)

```sql
-- FINOPS.WAREHOUSE_HOUR_COST
-- Reconciles hourly metered warehouse credits vs per-query attributed credits.
-- Note: QUERY_ATTRIBUTION_HISTORY can lag up to ~8 hours; use a freshness filter.

CREATE OR REPLACE VIEW FINOPS.WAREHOUSE_HOUR_COST AS
WITH metered AS (
  SELECT
      start_time                           AS hour_start,
      warehouse_id,
      warehouse_name,
      credits_used_compute                 AS metered_credits_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE warehouse_id > 0
),
attr AS (
  SELECT
      DATE_TRUNC('HOUR', start_time)       AS hour_start,
      warehouse_id,
      warehouse_name,
      SUM(credits_attributed_compute)      AS attributed_credits_compute,
      SUM(COALESCE(credits_used_query_acceleration, 0)) AS attributed_credits_qas
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  GROUP BY 1,2,3
)
SELECT
    m.hour_start,
    m.warehouse_id,
    m.warehouse_name,
    m.metered_credits_compute,
    COALESCE(a.attributed_credits_compute, 0) AS attributed_credits_compute,
    -- This is the remainder that QUERY_ATTRIBUTION_HISTORY does not assign to any query.
    -- Most commonly: warehouse idle time (and/or attribution gaps).
    (m.metered_credits_compute - COALESCE(a.attributed_credits_compute, 0)) AS idle_or_unattributed_credits_compute,
    COALESCE(a.attributed_credits_qas, 0) AS attributed_credits_qas
FROM metered m
LEFT JOIN attr a
  ON a.hour_start = m.hour_start
 AND a.warehouse_id = m.warehouse_id
;


-- FINOPS.QUERY_HOUR_COST
-- Joins query attribution to query metadata and optionally allocates idle remainder.
-- Allocation policy in this draft: allocate idle remainder proportionally by attributed credits within the same warehouse-hour.

CREATE OR REPLACE VIEW FINOPS.QUERY_HOUR_COST AS
WITH qa AS (
  SELECT
      query_id,
      warehouse_id,
      DATE_TRUNC('HOUR', start_time) AS hour_start,
      credits_attributed_compute,
      COALESCE(credits_used_query_acceleration, 0) AS credits_qas
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
),
qh AS (
  SELECT
      query_id,
      query_tag,
      user_name,
      role_name,
      -- Helpful for additional allocation variants (execution-time-based)
      TIMEADD('millisecond',
              queued_overload_time + compilation_time +
              queued_provisioning_time + queued_repair_time +
              list_external_files_time,
              start_time) AS execution_start_time,
      end_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
),
wh AS (
  SELECT * FROM FINOPS.WAREHOUSE_HOUR_COST
),
qa_hour_sum AS (
  SELECT warehouse_id, hour_start, SUM(credits_attributed_compute) AS sum_attr_credits
  FROM qa
  GROUP BY 1,2
)
SELECT
    qa.hour_start,
    qa.warehouse_id,
    qa.query_id,
    qh.query_tag,
    qh.user_name,
    qh.role_name,
    qa.credits_attributed_compute,
    qa.credits_qas,
    wh.metered_credits_compute,
    wh.idle_or_unattributed_credits_compute,

    -- Idle allocation (policy: proportional to attributed credits within the warehouse-hour)
    CASE
      WHEN COALESCE(qa_hour_sum.sum_attr_credits, 0) = 0 THEN NULL
      ELSE (qa.credits_attributed_compute / qa_hour_sum.sum_attr_credits)
           * wh.idle_or_unattributed_credits_compute
    END AS allocated_idle_credits_compute,

    -- Total "chargeback" credits with idle allocation
    (qa.credits_attributed_compute
      + COALESCE(
          CASE
            WHEN COALESCE(qa_hour_sum.sum_attr_credits, 0) = 0 THEN 0
            ELSE (qa.credits_attributed_compute / qa_hour_sum.sum_attr_credits)
                 * wh.idle_or_unattributed_credits_compute
          END,
          0
        )
    ) AS chargeback_credits_compute

FROM qa
JOIN wh
  ON wh.hour_start = qa.hour_start
 AND wh.warehouse_id = qa.warehouse_id
LEFT JOIN qa_hour_sum
  ON qa_hour_sum.hour_start = qa.hour_start
 AND qa_hour_sum.warehouse_id = qa.warehouse_id
LEFT JOIN qh
  ON qh.query_id = qa.query_id
;
```

Notes:
- This artifact intentionally keeps **metered credits** and **attributed credits** side-by-side to make “idle/unattributed remainder” a first-class quantity (useful both for analysis and for debugging attribution anomalies).
- We can later add additional allocation policies (execution-time-based, query-tag-based, “idle bucket”, etc.) as separate views/functions.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `WAREHOUSE_METERING_HISTORY` is the “anchor” for warehouse compute credits at an hourly grain | If metered credits include components not meant for query attribution, reconciliation could mislead | Compare to Snowsight Cost Management totals; ensure we’re using `CREDITS_USED_COMPUTE` consistently. (Docs note metering views are used for cost exploration.) |
| Idle remainder == only idle time | Remainder may include attribution gaps (e.g., excluded short queries) in addition to idle | Measure remainder distribution; correlate with query count/runtimes; explicitly label as “idle_or_unattributed”. (Docs: short queries excluded; idle excluded.) |
| Proportional-by-attributed-credits idle allocation is “fair” | Might misallocate idle created by infrequent queries that resume warehouses (min billing / auto-resume effects) | Consider alternative policies; allow customer-configurable model; compare to expectations on sample accounts. |
| `QUERY_ATTRIBUTION_HISTORY` may have quality issues in some environments | Could create false positives/negatives when identifying expensive queries | Add data-quality checks and explainers; cross-check with query timing-based approximations from `QUERY_HISTORY`. (Greybeam practitioner report.) |

## Links & Citations

1. Snowflake docs: `QUERY_ATTRIBUTION_HISTORY` view (columns, limits, idle excluded, short queries excluded, latency) — https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. Snowflake docs: Exploring compute cost (ACCOUNT_USAGE/ORG_USAGE, tags, billed cloud services via `METERING_DAILY_HISTORY`) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake docs: `QUERY_HISTORY` view (columns, 365d window, latency notes) — https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. Greybeam deep dive on query cost + idle time attribution and observed discrepancies — https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a second allocation policy variant that allocates idle remainder by **execution time** within the warehouse-hour (using `QUERY_HISTORY` timings), and compare outputs vs the proportional-by-attributed model.
- Add a “freshness window” filter (e.g., ignore last 8–10 hours) to reduce false anomalies due to `QUERY_ATTRIBUTION_HISTORY` latency.
- Extend the model to support rollups by `QUERY_TAG`, `USER_NAME`, `ROLE_NAME`, and/or custom org mappings (e.g., user→cost-center table) for chargeback.
