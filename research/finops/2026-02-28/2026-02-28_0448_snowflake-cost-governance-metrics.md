# Research: FinOps - 2026-02-28

**Time:** 04:48 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Resource monitors only apply to user-managed virtual warehouses**, and cannot track credit consumption for serverless features or AI services; Snowflake recommends **budgets** for monitoring those areas. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors
2. **Budgets** set a **monthly spending limit** and can monitor credit usage of **supported objects and serverless features**; budget notifications can be delivered to **email**, **cloud queues** (SNS / Event Grid / PubSub), or **webhooks** for third-party systems. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/user-guide/cost-controlling
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** for warehouse-executed queries over the last **365 days**, but:
   - excludes **warehouse idle time**, **cloud services**, **storage**, **data transfer**, **serverless**, and **AI token** costs
   - can lag by **up to 8 hours**
   - short-running queries (≈ **<=100ms**) are not included
   (Snowflake docs)  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly warehouse credit usage** over the last **365 days**; it includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` so you can estimate **idle** compute as compute-used minus query-attributed. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
5. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` returns **daily** credit usage (by `SERVICE_TYPE`) and includes a **cloud services rebate** concept for the account (last **365 days**). This is closer to “billing-facing” daily rollups than warehouse-hour views. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query warehouse compute credits; excludes idle time + serverless + AI tokens; latency up to ~8h; short queries (~<=100ms) excluded. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits used (compute + cloud services) and credits attributed to queries; latency up to 3h (cloud services col up to 6h). https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits + cloud services rebate, by service type, for last 365d. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORGANIZATION_USAGE` | Same concept at org level; useful when app spans multiple accounts. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history |
| `SHOW RESOURCE MONITORS` / `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | Command / View | Account metadata | Introspect quota/thresholds and monitor assignment patterns (doc is monitor semantics; view listing not extracted here). https://docs.snowflake.com/en/user-guide/resource-monitors |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Two-track attribution” daily dashboard**: report **query-attributed** credits (from `QUERY_ATTRIBUTION_HISTORY`) plus a **residual bucket** (idle + unattributed) derived from `WAREHOUSE_METERING_HISTORY` at warehouse-hour grain; expose reconciliation confidence.
2. **Budget/Resource-monitor coverage gap detector**: flag spend categories that **resource monitors can’t control** (serverless/AI) and prompt to set **budgets** + webhook notifications. (Budgets support webhook delivery.)
3. **Idle-cost leaderboard + remediation hints**: compute idle credits per warehouse per day and highlight warehouses with high idle share; tie to settings and operational best practices (auto-suspend, sizing, schedule, multi-cluster).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL: Allocate “idle” (residual) warehouse compute to query tags (hourly)

Goal: produce a tag-level view that includes (a) query-attributed compute credits + (b) a proportional share of idle credits, so tag totals reconcile more closely to warehouse compute.

> Notes:
> - `QUERY_ATTRIBUTION_HISTORY` excludes idle time by definition; this allocator is an explicit policy to distribute idle back to tags.
> - This does **not** cover serverless/AI tokens/storage/data transfer.

```sql
-- Tag-level cost rollup with an explicit idle allocator at warehouse-hour grain.
-- Inputs (ACCOUNT_USAGE):
--   - QUERY_ATTRIBUTION_HISTORY: per-query compute credits (no idle)
--   - WAREHOUSE_METERING_HISTORY: hourly compute used + credits attributed to queries

WITH q AS (
  SELECT
    DATE_TRUNC('HOUR', start_time)               AS hour_start,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '∅_NO_TAG')  AS query_tag,
    SUM(credits_attributed_compute)             AS credits_query_compute,
    SUM(COALESCE(credits_used_query_acceleration, 0)) AS credits_qas
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    AND start_time <  CURRENT_TIMESTAMP()
  GROUP BY 1,2,3
),

w AS (
  SELECT
    start_time::timestamp_ltz                   AS hour_start,
    warehouse_name,
    SUM(credits_used_compute)                   AS credits_wh_compute_used,
    SUM(credits_attributed_compute_queries)     AS credits_wh_attributed_to_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    AND start_time <  CURRENT_TIMESTAMP()
  GROUP BY 1,2
),

joined AS (
  SELECT
    q.hour_start,
    q.warehouse_name,
    q.query_tag,
    q.credits_query_compute,
    q.credits_qas,
    w.credits_wh_compute_used,
    w.credits_wh_attributed_to_queries,
    GREATEST(w.credits_wh_compute_used - w.credits_wh_attributed_to_queries, 0) AS credits_idle
  FROM q
  JOIN w
    ON q.hour_start = w.hour_start
   AND q.warehouse_name = w.warehouse_name
),

hour_totals AS (
  SELECT
    hour_start,
    warehouse_name,
    SUM(credits_query_compute) AS hour_query_compute_total
  FROM joined
  GROUP BY 1,2
)

SELECT
  j.hour_start,
  j.warehouse_name,
  j.query_tag,
  j.credits_query_compute,
  j.credits_qas,

  -- Policy: allocate idle in proportion to query-attributed compute for that warehouse-hour.
  CASE
    WHEN t.hour_query_compute_total = 0 THEN 0
    ELSE j.credits_idle * (j.credits_query_compute / t.hour_query_compute_total)
  END AS credits_idle_allocated,

  j.credits_query_compute
  + CASE
      WHEN t.hour_query_compute_total = 0 THEN 0
      ELSE j.credits_idle * (j.credits_query_compute / t.hour_query_compute_total)
    END
  + j.credits_qas AS credits_total_with_idle_plus_qas

FROM joined j
JOIN hour_totals t
  ON j.hour_start = t.hour_start
 AND j.warehouse_name = t.warehouse_name
ORDER BY 1 DESC, 2, 3;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Idle allocation policy (proportional to query-attributed compute) may be unfair for bursty workloads or tag sparsity. | Chargeback disputes / bad incentives. | Offer alternate policies: allocate by elapsed time, equal-split, or keep as “shared overhead” bucket; compare outcomes on historical periods. |
| `QUERY_ATTRIBUTION_HISTORY` excludes very short queries and can lag up to 8h. | Under-counting + near-real-time dashboards inaccurate. | Document latency; for “today” dashboards, add freshness indicators and/or fall back to warehouse-hour only. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history |
| Resource monitors include cloud services usage when evaluating limits, but do not account for the 10% cloud services adjustment. | Confusing mismatches between “quota reached” vs “billed.” | In the app, show monitor behavior separately from billing reconciliation; cite monitor semantics. https://docs.snowflake.com/en/user-guide/resource-monitors |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` may exceed billed credits and Snowflake suggests `METERING_DAILY_HISTORY` for billed reconciliation. | Bad reconciliation if you sum hourly credits directly. | Always reconcile to `METERING_DAILY_HISTORY` at daily grain for billing-facing charts. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |

## Links & Citations

1. Snowflake Docs — Working with resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
2. Snowflake Docs — Controlling cost (budgets + notifications/webhooks): https://docs.snowflake.com/en/user-guide/cost-controlling
3. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
5. Snowflake Docs — `METERING_DAILY_HISTORY` (account): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
6. Snowflake Docs — `METERING_DAILY_HISTORY` (org): https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history

## Next Steps / Follow-ups

- Extend the allocator to include an explicit **shared overhead bucket** (do not allocate idle) and let users choose policy per cost-center.
- Add a second reconciliation layer: map daily totals to `METERING_DAILY_HISTORY` (per `SERVICE_TYPE`) and show which categories are outside warehouses (serverless/AI/etc.).
- Pull in Snowflake’s “Attributing cost” guidance (object tags + query tags) and formalize an app-side tag schema + governance controls.
