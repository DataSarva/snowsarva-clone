# Research: FinOps - 2026-02-28

**Time:** 19:39 UTC  
**Topic:** Snowflake FinOps Cost Optimization — query-level cost attribution + idle-time reconciliation (Native App ready)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake recommends using **object tags** (e.g., tagging warehouses/users) and **query tags** (tagging sessions/queries) as the primary primitives for chargeback/showback cost attribution. 
2. **Per-query compute credits** are available via `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`, where `CREDITS_ATTRIBUTED_COMPUTE` explicitly **excludes warehouse idle time** and can have **up to ~8 hours latency**; very short-running queries (≈≤100ms) are excluded. 
3. `QUERY_ATTRIBUTION_HISTORY` is **account-scoped only** (no org-wide equivalent), which matters for a multi-account FinOps product: org rollups can be done for warehouse-level metering, but not for per-query attribution across accounts.
4. For “include idle time” reconciliation, Snowflake’s own examples show a pattern: compute the warehouse’s metered credits from `WAREHOUSE_METERING_HISTORY`, compute query-attributed credits from `QUERY_ATTRIBUTION_HISTORY`, then **allocate the difference** (idle/unattributed) proportionally across the attribution dimension (e.g., by `QUERY_TAG` or `USER_NAME`).
5. Snowflake’s general compute-cost exploration docs enumerate key cost/usage sources, including `METERING_DAILY_HISTORY` (for billed cloud-services adjustments) and list `APPLICATION_DAILY_USAGE_HISTORY` as a view for **Native Apps daily credit usage**.
6. Third-party validation work (Greybeam) suggests teams should **validate per-query attribution against `WAREHOUSE_METERING_HISTORY`** and may need custom logic for idle-time and edge cases; they also highlight potential anomalies (e.g., seemingly inflated credits for short queries) and note their need to model hourly metering explicitly.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits (`CREDITS_ATTRIBUTED_COMPUTE`) excludes idle time; latency up to ~8 hours; short queries (≈≤100ms) excluded; account-only. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (metered); useful for reconciliation and idle/unattributed calculation. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Map tagged objects/users to cost centers; used to attribute by warehouse or user tag. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Operational query metadata; can join by `QUERY_ID` for additional context (warehouse, role, client, timings). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to compute *billed* cloud services (10% adjustment) vs consumed; daily grain in UTC. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | `ACCOUNT_USAGE` | Useful for modeling suspend/resume/idle windows; third-party notes historical reliability concerns but claims improvements; still validate. |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Docs list this as daily credit usage for Snowflake Native Apps (candidate for in-app FinOps reporting). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution Engine v1 (SQL-only)**: materialize daily cost by `QUERY_TAG` (and optionally by `USER_NAME`) using `QUERY_ATTRIBUTION_HISTORY`, with an explicit “excludes idle time” disclaimer and an optional “allocate idle” toggle.
2. **Idle / Unattributed Credits Reconciler**: for a time window + warehouse filter, reconcile `SUM(WAREHOUSE_METERING_HISTORY.CREDITS_USED_COMPUTE)` vs `SUM(QUERY_ATTRIBUTION_HISTORY.CREDITS_ATTRIBUTED_COMPUTE)` and expose the delta as `UNATTRIBUTED_CREDITS` (often idle).
3. **Tag Hygiene Dashboard**: measure `untagged` share for both object tags and query tags; show top warehouses/users generating untagged spend.

## Concrete Artifacts

### SQL Draft: attribute warehouse credits to `QUERY_TAG`, with optional idle-time allocation

This is aligned with Snowflake’s own documented pattern (“including idle time” distributes the metered warehouse credits in proportion to query-attributed credits by tag).

```sql
-- Cost attribution by QUERY_TAG, with optional idle-time allocation
-- Window is last full month by default; adjust as needed.
--
-- Notes:
-- - QUERY_ATTRIBUTION_HISTORY excludes warehouse idle time and very short queries.
-- - This approach allocates the (metered - attributed) delta proportionally across tags.

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('MONTH', CURRENT_DATE())                    AS end_ts
),

wh_metered AS (
  SELECT
    SUM(wmh.credits_used_compute) AS metered_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  JOIN params p
    ON wmh.start_time >= p.start_ts
   AND wmh.start_time <  p.end_ts
  -- Optional: filter to a warehouse (or set of warehouses)
  -- WHERE wmh.warehouse_name IN ('WH_X', 'WH_Y')
),

tag_attributed AS (
  SELECT
    COALESCE(NULLIF(qah.query_tag, ''), 'untagged') AS tag,
    SUM(qah.credits_attributed_compute)            AS attributed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  JOIN params p
    ON qah.start_time >= p.start_ts
   AND qah.start_time <  p.end_ts
  GROUP BY 1
),

totals AS (
  SELECT SUM(attributed_credits) AS total_attributed_credits
  FROM tag_attributed
)

SELECT
  t.tag,
  t.attributed_credits,

  -- Idle/unattributed = metered - attributed (may include other effects; validate per warehouse/time)
  (wm.metered_credits - tot.total_attributed_credits) AS unattributed_credits,

  -- Allocate unattributed proportionally by tag attribution share
  IFF(
    tot.total_attributed_credits = 0,
    NULL,
    (t.attributed_credits / tot.total_attributed_credits) * (wm.metered_credits - tot.total_attributed_credits)
  ) AS allocated_unattributed_credits,

  -- "Including idle time" total (attribution + allocated delta)
  IFF(
    tot.total_attributed_credits = 0,
    NULL,
    t.attributed_credits
      + (t.attributed_credits / tot.total_attributed_credits) * (wm.metered_credits - tot.total_attributed_credits)
  ) AS total_credits_including_idle

FROM tag_attributed t
CROSS JOIN wh_metered wm
CROSS JOIN totals tot
ORDER BY total_credits_including_idle DESC NULLS LAST;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short queries (≈≤100ms). | Naive “cost per query” dashboards will undercount vs metered credits and miss short-query workloads. | Compare `SUM(CREDITS_ATTRIBUTED_COMPUTE)` to `SUM(WAREHOUSE_METERING_HISTORY.CREDITS_USED_COMPUTE)` for same window/warehouse. |
| Account-only scope of per-query attribution. | Native App cannot produce true org-wide per-query chargeback across multiple accounts without aggregating externally (or per-account collection). | Confirm product requirements: org rollup may be warehouse-level only; per-query remains per-account. |
| Latency (up to ~8 hours) in `QUERY_ATTRIBUTION_HISTORY`. | “Near-real-time” dashboards will look incomplete or wrong. | UI should label freshness; optionally use INFORMATION_SCHEMA table functions for low-latency operational dashboards (if acceptable) while maintaining ACCOUNT_USAGE for audit-grade. |
| Proportional allocation of idle/unattributed credits is a modeling choice (not necessarily Snowflake billing attribution). | Chargeback disputes if customers expect different allocation policy. | Offer multiple allocation policies: proportional-by-attributed, even-split, warehouse-owner, or “leave idle unallocated”. Document tradeoffs. |
| Third-party reports of anomalies (e.g., inflated attributed credits) may be account-specific or due to methodology. | Could lead to incorrect conclusions if adopted blindly. | Treat as a validation warning: run unit tests + sanity checks (e.g., attributed credits shouldn’t exceed metered credits at compatible grains). |

## Links & Citations

1. Snowflake Docs — Attributing cost (tags, query tags, allocation patterns, account vs org constraints): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` reference (latency, exclusions, columns, notes): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Exploring compute cost (key views incl. `METERING_DAILY_HISTORY`, and lists `APPLICATION_DAILY_USAGE_HISTORY` for Native Apps): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Greybeam deep dive (custom idle-time attribution approach + validation concerns): https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Turn the SQL draft into a **versioned view** inside the Native App (e.g., `FINOPS.COST_ATTRIBUTION_BY_QUERY_TAG_V1`) with parameter tables for windows + warehouse filters.
- Add a **reconciliation widget**: metered vs attributed vs unattributed, by warehouse and by day.
- Investigate `APPLICATION_DAILY_USAGE_HISTORY` more deeply for Native App product analytics: what dimensions exist (app name/id, owner, warehouse/serverless breakdown), and how it behaves for consumer accounts.
