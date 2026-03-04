# Research: FinOps - 2026-03-04

**Time:** 0546 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query attributed compute credits** for queries executed on warehouses in the last **365 days**, and the attributed credits **exclude warehouse idle time**. It can be filtered/aggregated by `QUERY_TAG`, `USER_NAME`, warehouse, and query hashes. [2]
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly warehouse credit usage** (last **365 days**) and includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which allows estimating warehouse **idle credits** as `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` over a time range. [3]
3. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` (and compute/cloud-services components) may be **higher than billed credits** (because of cloud services adjustment); Snowflake docs recommend using `METERING_DAILY_HISTORY` to determine **billed** credits. [3]
4. Object tags are schema-level objects; Snowflake supports **tag inheritance/propagation**, and you can query tag lineage/association methods via `TAG_REFERENCES` (views/functions expose `apply_method`). Tagging warehouses enables resource usage monitoring and grouping by cost center / org unit. [4]
5. A practical cost attribution strategy is: use **object tags** for dedicated resources (e.g., a warehouse dedicated to a cost center) and **query tags** for shared resources where multiple teams share compute. [1]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed compute credits (excludes idle); includes `QUERY_TAG`; latency up to ~8h; short-running queries (<=~100ms) may be missing. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (idle math); `CREDITS_USED` not necessarily billed; timezone reconciliation note (set session TZ to UTC when comparing to ORG views). [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Mentioned as join point for allocating usage to business groups (used with metering + storage metrics). [1] *(Columns/semantics not extracted in this session.)* |
| `INFORMATION_SCHEMA.TAG_REFERENCES(...)` | Table function | `INFO_SCHEMA` | Returns `apply_method` and can be used to understand whether tag was manual vs inherited/propagated, etc. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query tags appear here and can be used for workload attribution; recommended pairing with tagging strategy. [1] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Two-lane cost attribution model in the Native App**: compute **attributed compute** (per query tag) via `QUERY_ATTRIBUTION_HISTORY`, and compute **idle tax** via `WAREHOUSE_METERING_HISTORY`; show both side-by-side (teams can choose “attributed-only” vs “all-in including idle”). [2][3]
2. **Tag hygiene & coverage report**: report warehouses/users/databases without required tags (e.g., `COST_CENTER`, `ENV`) and identify whether tags are inherited/propagated using `TAG_REFERENCES` / `apply_method`. [4]
3. **Idle inefficiency leaderboard**: daily/weekly ranking of warehouses by idle credits (or idle %) with a drill-through to recommended controls (auto-suspend, right-size, multi-cluster settings) (controls referenced in cost optimization guidance). [1][3]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: “All-in” (incl idle) cost attribution by QUERY_TAG

Goal: Allocate warehouse-hour compute credits to `QUERY_TAG` using `QUERY_ATTRIBUTION_HISTORY` for “active” compute plus a proportional share of warehouse-hour idle.

Notes / constraints:
- `QUERY_ATTRIBUTION_HISTORY` credits exclude idle time. [2]
- Idle credits can be estimated per warehouse-hour using `WAREHOUSE_METERING_HISTORY`. [3]
- This draft focuses on **compute credits**; cloud services credits are trickier to allocate accurately and may be adjusted vs billed. [3]

```sql
-- Parameters
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

-- 1) Warehouse-hour baseline: compute used + compute attributed to queries
WITH wh_hour AS (
  SELECT
    DATE_TRUNC('hour', start_time)               AS hour_ts,
    warehouse_name,
    SUM(credits_used_compute)                   AS wh_compute_used_credits,
    SUM(credits_attributed_compute_queries)     AS wh_compute_attributed_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1,2
),

-- 2) Query-level attribution aggregated to warehouse-hour + query_tag
qtag_hour AS (
  SELECT
    DATE_TRUNC('hour', start_time)              AS hour_ts,
    warehouse_name,
    COALESCE(NULLIF(query_tag, ''), '__NO_TAG__') AS query_tag,
    SUM(credits_attributed_compute
        + COALESCE(credits_used_query_acceleration, 0)) AS qtag_attributed_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1,2,3
),

-- 3) Denominator per warehouse-hour (for proportional idle allocation)
qtag_hour_tot AS (
  SELECT hour_ts, warehouse_name, SUM(qtag_attributed_credits) AS total_attributed_credits
  FROM qtag_hour
  GROUP BY 1,2
)

SELECT
  h.hour_ts,
  h.warehouse_name,
  q.query_tag,

  -- Active (attributed) compute
  q.qtag_attributed_credits                                        AS attributed_compute_credits,

  -- Idle computed at warehouse-hour
  GREATEST(h.wh_compute_used_credits - h.wh_compute_attributed_credits, 0) AS warehouse_idle_credits,

  -- Proportional idle allocation (if no attributed credits in the hour, idle stays unallocated)
  CASE
    WHEN t.total_attributed_credits > 0 THEN
      (q.qtag_attributed_credits / t.total_attributed_credits)
      * GREATEST(h.wh_compute_used_credits - h.wh_compute_attributed_credits, 0)
    ELSE 0
  END AS allocated_idle_credits,

  -- All-in compute = attributed + allocated idle
  q.qtag_attributed_credits
  + CASE
      WHEN t.total_attributed_credits > 0 THEN
        (q.qtag_attributed_credits / t.total_attributed_credits)
        * GREATEST(h.wh_compute_used_credits - h.wh_compute_attributed_credits, 0)
      ELSE 0
    END AS all_in_compute_credits

FROM wh_hour h
JOIN qtag_hour q
  ON q.hour_ts = h.hour_ts
 AND q.warehouse_name = h.warehouse_name
LEFT JOIN qtag_hour_tot t
  ON t.hour_ts = h.hour_ts
 AND t.warehouse_name = h.warehouse_name
ORDER BY 1,2,3;
```

How to use in-app:
- Default view: group `all_in_compute_credits` by `query_tag` (and optionally by day/week).
- Show “unallocated idle” per warehouse-hour when `total_attributed_credits = 0` (common on hours with only very short queries or purely non-attributed work). [2]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes very short queries (<=~100ms). | Attribution totals can undercount, skewing idle allocation (idle looks bigger than reality). [2] | Compare totals vs warehouse compute used and check for systematic gaps. |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED*` may not equal billed credits. | “All-in credits” may not reconcile to invoice; dollar conversion could be off if you assume it is billed. [3] | Use `METERING_DAILY_HISTORY` when reconciling to billed credits. [3] |
| Idle allocation proportional to attributed compute is a policy choice. | Different teams may dispute fairness (e.g., who pays for warm cache / reserved capacity). | Provide both “attributed-only” and “all-in including idle” views; document policy. |
| Tag strategy depends on governance: object tags vs query tags. | Inconsistent tagging breaks chargeback/showback. [1][4] | Enforce required tags at provisioning time; add compliance checks. |

## Links & Citations

1. Snowflake Well-Architected Framework (Cost Optimization & FinOps guide) (updated Nov 23, 2025): https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/  
2. `QUERY_ATTRIBUTION_HISTORY` (ACCOUNT_USAGE) docs: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history  
3. `WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE) docs: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history  
4. Object tagging introduction (tag inheritance/propagation, `TAG_REFERENCES`, quotas): https://docs.snowflake.com/en/user-guide/object-tagging/introduction

## Next Steps / Follow-ups

- Pull the `TAG_REFERENCES` view doc next session and draft a concrete join pattern: warehouse tags (cost center / env) → `WAREHOUSE_METERING_HISTORY` + query-tag attribution.
- Add an ADR in `research/finops` for the Native App: “Two-lane attribution (attributed-only vs all-in incl idle) + reconciliation to billed credits”.
