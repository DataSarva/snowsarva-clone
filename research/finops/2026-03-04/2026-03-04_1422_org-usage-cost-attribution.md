# Research: FinOps - 2026-03-04

**Time:** 14:22 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended primitives for chargeback/showback are **object tags** (for resources/users) and **query tags** (for applications issuing queries on behalf of different cost centers).\
   Source: Snowflake “Attributing cost” guide.\
   https://docs.snowflake.com/en/user-guide/cost-attributing
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute attribution** (`CREDITS_ATTRIBUTED_COMPUTE`) but **does not include warehouse idle time**, and it can have **up to ~8 hours latency**.\
   Source: `QUERY_ATTRIBUTION_HISTORY` reference.\
   https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. `QUERY_ATTRIBUTION_HISTORY` explicitly excludes **non-warehouse costs** (e.g., storage, data transfer, serverless features, AI token costs) and also excludes **very short queries (~<=100ms)** from per-query attribution.\
   Source: `QUERY_ATTRIBUTION_HISTORY` reference + “Attributing cost” guide.\
   https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history\
   https://docs.snowflake.com/en/user-guide/cost-attributing
4. Organization-wide cost views exist in `SNOWFLAKE.ORGANIZATION_USAGE` for many domains (e.g., `WAREHOUSE_METERING_HISTORY`), but there is **no org-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`; query-level attribution is **account-scoped**.\
   Source: “Attributing cost” guide.\
   https://docs.snowflake.com/en/user-guide/cost-attributing
5. Snowflake’s compute-cost exploration docs emphasize that many views report **credits consumed** (not necessarily credits billed), and point to `METERING_DAILY_HISTORY` for reconciling what was actually billed for cloud services (billed only when cloud services credits exceed 10% of warehouse usage that day).\
   Source: “Exploring compute cost” guide.\
   https://docs.snowflake.com/en/user-guide/cost-exploring-compute
6. Snowflake documents a first-party view `APPLICATION_DAILY_USAGE_HISTORY` for **Snowflake Native Apps** credit usage (daily, last 365 days) as part of feature-specific compute cost views.\
   Source: “Exploring compute cost” guide.\
   https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | `ACCOUNT_USAGE` | Per-query compute credits; excludes idle time; <=~100ms queries excluded; latency up to 8 hours. [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Warehouse-level hourly credits; used as “bill” anchor for compute credits. Referenced in attribution examples. [Docs](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | `ACCOUNT_USAGE` | Map tags to objects/users; used to attribute costs by tag. [Docs](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ORG_USAGE` | Org-wide warehouse metering; allows cross-account rollups for dedicated resources (but not per-query). [Docs](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | `ACCOUNT_USAGE` | Used to reconcile billed cloud services via adjustment columns; recommended in compute-cost exploration docs. [Docs](https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | view | `ACCOUNT_USAGE` | Daily credit usage for Snowflake Native Apps (account-scoped). Listed in compute-cost exploration docs. [Docs](https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag hygiene” dashboard + alerts:**
   - KPI: % of `QUERY_ATTRIBUTION_HISTORY` credits where `query_tag` is NULL/empty or the `USER`/`WAREHOUSE` lacks a `cost_center` tag.
   - Directly aligns with Snowflake’s recommended approach (object tags + query tags).\
   Sources: https://docs.snowflake.com/en/user-guide/cost-attributing
2. **Idle-time-aware showback for query tags (account-scoped):**
   - Provide two numbers per cost center/tag: (a) attributed query compute (from `QUERY_ATTRIBUTION_HISTORY`), and (b) “all-in” warehouse compute by proportionally distributing the gap between `WAREHOUSE_METERING_HISTORY` and query-attributed credits.
   - This matches Snowflake’s own example approach for distributing idle time proportionally.\
   Sources: https://docs.snowflake.com/en/user-guide/cost-attributing
3. **Native App compute rollup card:**
   - Pull daily credits from `APPLICATION_DAILY_USAGE_HISTORY` to expose “App overhead” separately from warehouse/serverless consumption (where available).
   - Use this to make Native App ROI transparent.\
   Sources: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Concrete Artifacts

### SQL Draft: “All-in credits by QUERY_TAG (includes idle distribution)”

Goal: produce an account-level table of compute credits by `query_tag` that (1) sums per-query credits, and (2) scales them to the warehouse bill (thus allocating idle time proportionally across tags), following the documented example pattern.

```sql
-- All-in warehouse compute credits attributed to QUERY_TAG, including idle time.
--
-- Notes:
-- - QUERY_ATTRIBUTION_HISTORY excludes idle time and very short queries (<=~100ms).
-- - This query distributes the *difference* between warehouse metering and attributed query credits
--   proportionally across tags (including an 'untagged' bucket).
--
-- Sources:
-- - https://docs.snowflake.com/en/user-guide/cost-attributing
-- - https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history

WITH params AS (
  SELECT
    DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('month', CURRENT_DATE()) AS end_ts
),

-- 1) Warehouse metering = the "bill" to reconcile against
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS wh_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
),

-- 2) Query-attributed credits by query tag (idle excluded)
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS q_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts   FROM params)
  GROUP BY 1
),

total_q AS (
  SELECT SUM(q_credits) AS total_q_credits
  FROM tag_credits
)

SELECT
  tc.tag,
  tc.q_credits                                   AS credits_attributed_compute_ex_idle,
  (tc.q_credits / NULLIF(tq.total_q_credits, 0))
    * wb.wh_credits                              AS credits_attributed_all_in_including_idle
FROM tag_credits tc
CROSS JOIN total_q tq
CROSS JOIN wh_bill wb
ORDER BY credits_attributed_all_in_including_idle DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes warehouse idle time and <=~100ms queries. | If we build UI around only per-query credits, it may understate true warehouse spend; if we distribute idle proportionally, we may "overcharge" heavy tags for others' idle drivers. | Compare totals vs `WAREHOUSE_METERING_HISTORY`; optionally publish both numbers in UI. Sources: [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing), [QUERY_ATTRIBUTION_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history) |
| Org-wide query-level attribution is not available (no ORG_USAGE equivalent for `QUERY_ATTRIBUTION_HISTORY`). | Native App may need a per-account “drill-down” UX for query-level details, plus an org-level summary for warehouse-level usage. | Confirmed in Snowflake docs. Source: [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| Cloud services billed credits differ from consumed credits (10% rule). | FinOps reports can be inconsistent with billing invoices if we only show consumed credits. | Provide a “Billing reconciliation” page using `METERING_DAILY_HISTORY`. Source: [Exploring compute cost](https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |

## Links & Citations

1. Snowflake docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs — `QUERY_ATTRIBUTION_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Extend the SQL draft to produce results by **day** (or hour) + `query_tag`, and optionally join to `TAG_REFERENCES` to map `USER`/`WAREHOUSE` cost_center tags.
- Add a second "mode": allocate idle at the **warehouse level first**, then to tags within each warehouse (reduces cross-warehouse distortion).
- Investigate `APPLICATION_DAILY_USAGE_HISTORY` shape/columns and whether it can be joined to other usage tables for richer Native App cost breakdowns (still within `ACCOUNT_USAGE`).
