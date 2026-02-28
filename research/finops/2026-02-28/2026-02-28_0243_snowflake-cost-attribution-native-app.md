# Research: FinOps - 2026-02-28

**Time:** 02:43 UTC  
**Topic:** Snowflake FinOps Cost Optimization (query-level attribution + idle time + tagging for showback/chargeback)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** for queries run on warehouses, but it **excludes warehouse idle time** and can have **up to ~8 hours of latency**. It also **excludes very short queries (~<=100ms)**. (Snowflake docs)  
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` is the **hourly “source of truth”** for warehouse credits (compute + cloud services per warehouse/hour). This view is what reconciles to warehouse metering/consumption dashboards. (Snowflake docs)
3. The *Information Schema* table function `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` is convenient for ad-hoc usage but is limited to **the last 6 months** and can be incomplete for long multi-warehouse queries; for completeness, Snowflake recommends using the **ACCOUNT_USAGE view**. (Snowflake docs)
4. In Snowflake’s cost-exploration guidance, cloud services credits are **only billed** if the day’s cloud services consumption exceeds **10%** of that day’s warehouse usage; to determine what was actually billed, Snowflake suggests querying `METERING_DAILY_HISTORY`. (Snowflake docs)
5. Third-party analysis (Greybeam) reports possible discrepancies in early usage of `QUERY_ATTRIBUTION_HISTORY` (e.g., inflated attribution for short runtimes, warehouse_id mismatch). Regardless of whether those issues reproduce, this is a strong signal that a FinOps product should support **validation + reconciliation workflows** rather than treating query attribution as unquestioned ground truth. (Greybeam blog)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Query-level compute credits (excludes idle; short queries omitted; latency up to ~8h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Required to add dimensions not present/complete in attribution view (role/user/client, query_text, timings, etc.). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (compute + cloud services columns). Reconciliation anchor. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily compute credits + cloud services adjustments; use for “billed vs consumed” semantics. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | Last 6 months only; may be incomplete for long multi-warehouse/time range queries. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | `ACCOUNT_USAGE` | Needed if we want to *explicitly* delineate suspend/resume and more precisely allocate idle windows. Mentioned in Greybeam method. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Query attribution + reconciliation report**: For each warehouse-hour, show `metered_credits_used_compute` vs `sum(query_attribution)` and compute a “residual/idle/unattributed” bucket. This makes the idle-time gap explicit and gives a direct QA check for attribution.
2. **Tag-driven showback on query attribution**: Group attributed credits by `QUERY_TAG` (or by parsed JSON in `QUERY_TAG`) to get a clean chargeback dimension that’s controllable by customers.
3. **Hybrid allocator (attributed + residual)**: Allocate residual credits (idle/unattributed) by a deterministic policy (e.g., proportionally to attributed credits by tag within that warehouse-hour; or allocate to a dedicated “Idle/Overhead” cost center). Make the policy explicit and configurable.

## Concrete Artifacts

### ADR-0003: “Two-track compute cost attribution” (query-attributed + residual allocator)

**Context**  
We want per-team/per-app/showback reporting inside a Native App. Snowflake now provides `QUERY_ATTRIBUTION_HISTORY` for warehouse compute credits at query granularity, but it explicitly excludes idle time and can have latency; meanwhile `WAREHOUSE_METERING_HISTORY` provides the billed/consumed credit anchor at hourly grain.

**Decision**  
Implement attribution as **two tracks**:

- Track A (Query-attributed): consume `QUERY_ATTRIBUTION_HISTORY` as authoritative *for “active query execution compute credits”*.
- Track B (Residual): compute residual credits per warehouse-hour as:
  - `residual_compute_credits = wmh.credits_used_compute - sum(qah.credits_attributed_compute)`
  - (optionally include cloud services separately using `credits_used_cloud_services` for warehouse cloud-services attribution, recognizing overall billing adjustment occurs daily)

Then allocate residual based on a configurable policy:

- Policy P0: do not allocate (report residual bucket)
- Policy P1: allocate proportional to attributed credits by tag/user within that warehouse-hour
- Policy P2: allocate proportional to execution time by tag/user within that warehouse-hour (requires `QUERY_HISTORY` timings)

**Consequences**  
- We can reconcile and explain why query-attributed totals don’t match warehouse totals.
- Customers get explicit idle/overhead accounting, which is usually where “mystery spend” lives.
- Additional computation is required (warehouse-hour joins; possible heavy scanning if not incremental).

### SQL draft: hourly attribution + residual bucket (warehouse compute)

```sql
-- Purpose: reconcile warehouse-hour metered credits vs query-attributed credits.
-- Output is suitable for a Native App to build: (1) validation widgets, (2) residual allocator inputs.
--
-- Source of truth (metered):   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Query attribution (partial): SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- Optional enrichment:         SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY

SET START_TS = DATEADD('day', -7, CURRENT_TIMESTAMP());

WITH wmh AS (
  SELECT
    start_time AS hour_start,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $START_TS
    AND warehouse_id > 0  -- skip pseudo warehouses like CLOUD_SERVICES_ONLY
),

qah AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    warehouse_id,
    SUM(credits_attributed_compute) AS attributed_compute_credits,
    COUNT(*) AS attributed_query_count
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $START_TS
  GROUP BY 1,2
)

SELECT
  wmh.hour_start,
  wmh.warehouse_id,
  wmh.warehouse_name,
  wmh.credits_used_compute,
  COALESCE(qah.attributed_compute_credits, 0) AS attributed_compute_credits,
  (wmh.credits_used_compute - COALESCE(qah.attributed_compute_credits, 0)) AS residual_compute_credits,
  COALESCE(qah.attributed_query_count, 0) AS attributed_query_count,
  wmh.credits_used_cloud_services,
  wmh.credits_used
FROM wmh
LEFT JOIN qah
  ON wmh.hour_start = qah.hour_start
 AND wmh.warehouse_id = qah.warehouse_id
ORDER BY 1 DESC, 2;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` explicitly excludes idle time and short queries; residual may be large and misinterpreted as “waste”. | Customers may overreact; product must explain residual semantics clearly. | Add tooltip/explainers + link to Snowflake docs; show “% residual” trend over time. |
| `QUERY_ATTRIBUTION_HISTORY` latency (up to ~8h) causes temporary mismatches vs `WAREHOUSE_METERING_HISTORY`. | Dashboards can look “wrong” in near-real-time windows. | Add “data freshness” watermark; avoid near-real-time reconciliation or use lagged windows. |
| Daily cloud services billing adjustment (10% threshold) means “consumed credits” != “billed credits” for cloud services. | Incorrect cost-in-currency if we naïvely sum cloud services consumption. | Use `METERING_DAILY_HISTORY` for billed semantics and surface both “consumed” and “billed”. |
| Third-party reports potential anomalies (inflated attribution, warehouse_id mismatch). | Potential data correctness issues in some accounts/periods; undermines trust. | Provide a “recompute using metering allocation” fallback and/or an audit mode; encourage cross-checking. |

## Links & Citations

1. Snowflake Docs – Exploring compute cost (cost mgmt dashboards, tags, metering views, cloud services 10% adjustment): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. Snowflake Docs – `QUERY_ATTRIBUTION_HISTORY` (latency, exclusions, column semantics): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs – `WAREHOUSE_METERING_HISTORY` Information Schema table function (6-month limit; prefer ACCOUNT_USAGE view for completeness): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
4. Greybeam blog – analysis + caveats + methodology to allocate idle time using metering history: https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a second SQL artifact that groups `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG` + `WAREHOUSE_NAME` + day, and joins residual allocation (Policy P1).
- Research Snowflake docs for `WAREHOUSE_UTILIZATION` (mentioned by Greybeam) and whether it is generally available now vs support-enabled.
- Confirm the best native view for “billed credits” vs “consumed credits” for warehouses + cloud services in a single daily reconciler (likely `METERING_DAILY_HISTORY`, plus currency conversions where available).
