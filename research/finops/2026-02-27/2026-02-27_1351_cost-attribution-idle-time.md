# Research: FinOps - 2026-02-27

**Time:** 13:51 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + idle time)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s recommended SQL-based cost attribution approach is to **tag warehouses/users** and then join **`SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`** to usage views such as **`WAREHOUSE_METERING_HISTORY`** (warehouse credits) and **`QUERY_ATTRIBUTION_HISTORY`** (per-query compute credits). [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` attributes **compute credits per query** (and optionally query acceleration credits), but **explicitly excludes warehouse idle time** and excludes very short queries (≈ <= 100ms). Latency can be up to **~8 hours**. [2]
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes both total warehouse compute credits and the subset attributed to queries (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`). Snowflake’s docs provide a simple way to compute **idle cost** for a warehouse over a period as:
   `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)`. [3]
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` is the **account-level** hourly credits view across many service types (warehouses, serverless features, etc.), keyed by `SERVICE_TYPE` (e.g., `WAREHOUSE_METERING`, `SNOWPARK_CONTAINER_SERVICES`, `QUERY_ACCELERATION`, `AI_SERVICES`, etc.). Typical latency is up to **~180 minutes**, with some columns having higher latency (cloud services up to ~6h; Snowpipe Streaming up to ~12h). [4]
5. For compute cost exploration, Snowflake points users to query `ACCOUNT_USAGE` / `ORGANIZATION_USAGE` views; to express cost in currency, Snowflake directs users to **`USAGE_IN_CURRENCY_DAILY`** (org-level) rather than working purely in credits. [5]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | View | ACCOUNT_USAGE | Maps tags to objects (warehouses/users/etc.) for cost attribution joins. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly warehouse credit usage (compute + cloud services) + `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` used for idle-time calculation. [3] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query compute cost (`CREDITS_ATTRIBUTED_COMPUTE`) and QAS credits; excludes idle time; latency up to ~8h. [2] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits by `SERVICE_TYPE` across account (warehouse + serverless + cloud services + others). [4] |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | View | ORG_USAGE | Daily credits + currency conversion at daily credit price (per Snowflake guidance for currency reporting). [5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle-time allocator (baseline “chargeback”)**: Produce a daily/weekly cost-by-(query_tag or cost_center tag) report where **idle time is distributed proportionally** to active query attribution (so business owners see “all-in” warehouse cost, not just execution cost).
2. **Data freshness/latency UX**: In the app UI, annotate charts with **expected latency** by source (e.g., 3h for WAREHOUSE_METERING_HISTORY vs up to 8h for QUERY_ATTRIBUTION_HISTORY) and show “data complete through <timestamp>”.
3. **Cross-service spend lens**: Use `METERING_HISTORY.SERVICE_TYPE` to build a “top non-warehouse cost drivers” panel (e.g., Snowpipe, Search Optimization, Snowpark Container Services, AI Services) with drill-down by ENTITY/NAME where available.

## Concrete Artifacts

### SQL draft: Allocate warehouse idle credits to query tags (proportional allocation)

**Goal:** Provide a single query that yields *all-in* warehouse compute credits by `QUERY_TAG` by taking:
- per-query attributed credits (from `QUERY_ATTRIBUTION_HISTORY`) and
- the residual idle credits (from `WAREHOUSE_METERING_HISTORY`),
then distributing idle credits across tags proportionally to the tags’ attributed credits.

```sql
-- All-in warehouse compute credits by QUERY_TAG (includes idle-time allocation)
-- Sources:
--   * SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY  (per-query, excludes idle time)
--   * SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (warehouse metering + query-attributed subtotal)
-- Notes:
--   * Uses hour grain to align with metering.
--   * QUERY_TAG may be NULL/empty; normalized to 'untagged'.

WITH
params AS (
  SELECT
    DATEADD('day', -30, CURRENT_TIMESTAMP()) AS start_ts,
    CURRENT_TIMESTAMP() AS end_ts
),

q_tag_hour AS (
  SELECT
    warehouse_id,
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_start,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS tag_attributed_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
  GROUP BY 1,2,3,4
),

q_tot_hour AS (
  SELECT
    warehouse_id,
    hour_start,
    SUM(tag_attributed_credits) AS total_attributed_credits
  FROM q_tag_hour
  GROUP BY 1,2
),

wh_hour AS (
  SELECT
    warehouse_id,
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_start,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
  GROUP BY 1,2,3
),

all_in_by_tag_hour AS (
  SELECT
    wh.warehouse_name,
    wh.hour_start,
    q.query_tag,
    q.tag_attributed_credits,
    wh.idle_credits,

    /* Allocate idle credits proportionally to attributed credits in the same warehouse-hour */
    CASE
      WHEN COALESCE(t.total_attributed_credits, 0) = 0 THEN 0
      ELSE (q.tag_attributed_credits / t.total_attributed_credits) * wh.idle_credits
    END AS idle_allocated_credits,

    /* "All-in" credits for the tag */
    q.tag_attributed_credits
      + CASE
          WHEN COALESCE(t.total_attributed_credits, 0) = 0 THEN 0
          ELSE (q.tag_attributed_credits / t.total_attributed_credits) * wh.idle_credits
        END AS all_in_credits

  FROM wh_hour wh
  JOIN q_tag_hour q
    ON q.warehouse_id = wh.warehouse_id
   AND q.hour_start   = wh.hour_start
  LEFT JOIN q_tot_hour t
    ON t.warehouse_id = wh.warehouse_id
   AND t.hour_start   = wh.hour_start
)

SELECT
  query_tag,
  SUM(all_in_credits) AS all_in_compute_credits_30d,
  SUM(tag_attributed_credits) AS execution_compute_credits_30d,
  SUM(idle_allocated_credits) AS idle_allocated_credits_30d
FROM all_in_by_tag_hour
GROUP BY 1
ORDER BY all_in_compute_credits_30d DESC;
```

**Why this matters for the Native App:** `QUERY_ATTRIBUTION_HISTORY` is powerful but under-represents cost for low-utilization warehouses. This query turns it into something closer to “billable reality” by including the residual idle portion (using metering truth). [2][3]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| `QUERY_ATTRIBUTION_HISTORY` latency (up to ~8h) + exclusions (very short queries) means execution attribution can be incomplete for recent hours. | “All-in by tag” can swing during the day; near-real-time dashboards might be misleading. | Build a “data completeness horizon” and compare `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` vs SUM(qah credits) by hour to spot gaps. [2][3] |
| Idle allocation proportional to attributed credits may not reflect Snowflake’s internal attribution logic (multi-cluster, resizing, concurrency). | Chargeback perceived as unfair by some teams; might require alternative models. | Offer multiple allocation models (proportional to execution credits; proportional to query count; per-user; fixed split) and let admins choose. |
| Service-type costs (from `METERING_HISTORY`) are diverse; `ENTITY_ID/NAME` semantics vary by service type. | Harder to provide a uniform drill-down UX. | Implement a per-`SERVICE_TYPE` metadata map (what NAME means, which dimensions are stable). [4] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
5. https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Add a “cost model” section to the FinOps Native App design: (A) execution-only attribution vs (B) execution + idle allocation (this note’s SQL) vs (C) warehouse-level tag attribution (warehouse tag join).
- Consider a “latency-aware ETL” pattern: periodically materialize hourly aggregates into app-owned tables to avoid heavy scans on account usage views and to freeze reporting windows.
