# Research: FinOps - 2026-02-27

**Time:** 11:44 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides per-query **warehouse compute** credit attribution for the last 365 days, but it **excludes warehouse idle time** and can have **up to ~8 hours latency**. Queries running **<= ~100ms** are not included. [Snowflake Docs]
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly account-level credit usage** for the last 365 days, with `SERVICE_TYPE` breaking out warehouse metering vs serverless features (e.g., `PIPE`, `AUTO_CLUSTERING`, `SNOWPARK_CONTAINER_SERVICES`, etc.) and includes `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`. [Snowflake Docs]
3. Cost attribution “including idle time” can be performed by (a) summing metered warehouse credits from `WAREHOUSE_METERING_HISTORY`, (b) summing attributed credits from `QUERY_ATTRIBUTION_HISTORY` by dimension (e.g., query_tag), then (c) scaling those attributed credits proportionally so that the total matches metered warehouse credits. Snowflake documents this proportional distribution approach for users/tags. [Snowflake Docs]
4. The Information Schema table function `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` returns hourly warehouse usage for **the last 6 months** and may be incomplete for long multi-warehouse ranges; Snowflake recommends `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` when you need completeness over longer periods. [Snowflake Docs]
5. A practical concern raised by third-party practitioners: they observed cases where aggregations of `QUERY_ATTRIBUTION_HISTORY` appeared unexpectedly large vs metered credits, and recommend validating against `WAREHOUSE_METERING_HISTORY` and filing support tickets if mismatches appear. (Treat as anecdotal until validated in a target account.) [Greybeam]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query attributed credits for warehouse execution; excludes idle time; latency up to 8 hours; <~100ms queries excluded. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to join query metadata (text/type/timing) to per-query credits for drilldowns; not extracted deeply in this pass. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly metered credits by warehouse (the “billed” source of truth to reconcile to). (Referenced in Snowflake cost attribution examples.) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account-level credits by service_type; helpful for top-level spend composition and non-warehouse costs. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` (and `ORG_USAGE` org acct) | Map tags to objects/users; used to attribute by `cost_center`, etc. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | 6 month lookback; requires ACCOUNTADMIN or `MONITOR USAGE`. Use view for longer completeness. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Metered vs Attributed” gap widget**: for a time window, show `metered_warehouse_credits` (from `WAREHOUSE_METERING_HISTORY`) vs `sum(query_attributed_compute)` (from `QUERY_ATTRIBUTION_HISTORY`) and compute the delta = **idle/unattributed**. This becomes the basis for “waste” tracking and autosuspend policy recommendations.
2. **Chargeback modes toggle**:
   - *Execution-only*: show `QUERY_ATTRIBUTION_HISTORY` by query_tag/user.
   - *Execution + idle*: distribute idle proportionally using the Snowflake-documented scaling method so totals reconcile to metered credits.
3. **Data freshness & completeness guardrails**: surface the documented latency for `QUERY_ATTRIBUTION_HISTORY` (up to 8 hours) and `METERING_HISTORY` (up to 3 hours, with some fields longer) so dashboards don’t pretend they’re real-time.

## Concrete Artifacts

### SQL: attribute warehouse credits by `QUERY_TAG` **including idle time** (proportional scaling)

This follows the Snowflake-documented pattern: compute metered warehouse credits, compute per-tag execution credits, then scale execution credits so totals reconcile to metered credits (idle is implicitly distributed proportionally).

```sql
-- Attribute WAREHOUSE metered credits to query_tag, including idle time (proportional allocation).
-- Sources:
--  - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--  - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- Notes:
--  - QUERY_ATTRIBUTION_HISTORY excludes idle time and excludes <=~100ms queries.
--  - Consider running in UTC if you reconcile across ACCOUNT_USAGE vs ORG_USAGE.

SET start_time = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_time   = CURRENT_TIMESTAMP();

WITH
-- 1) Source of truth for warehouse compute that was metered/billed.
wh_metered AS (
  SELECT
    SUM(credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_time
    AND start_time <  $end_time
),

-- 2) Sum attributed execution credits by tag.
--    (These will NOT sum to metered credits because idle time is excluded.)
tag_exec AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_norm,
    SUM(credits_attributed_compute)            AS exec_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_time
    AND start_time <  $end_time
  GROUP BY 1
),

total_exec AS (
  SELECT SUM(exec_credits) AS total_exec_credits
  FROM tag_exec
)

SELECT
  t.query_tag_norm                           AS query_tag,
  t.exec_credits                             AS execution_only_credits,
  -- Scale up/down execution credits to reconcile to metered warehouse compute.
  (t.exec_credits / NULLIF(te.total_exec_credits, 0))
    * wm.metered_compute_credits             AS execution_plus_idle_allocated_credits,
  -- The difference is the share of idle/unattributed allocated to this tag.
  ((t.exec_credits / NULLIF(te.total_exec_credits, 0))
    * wm.metered_compute_credits) - t.exec_credits AS allocated_idle_credits
FROM tag_exec t
CROSS JOIN total_exec te
CROSS JOIN wh_metered wm
ORDER BY execution_plus_idle_allocated_credits DESC;
```

**What this enables in the app:**
- A consistent “showback” story where totals reconcile to metered warehouse compute.
- An explicit “idle allocation” column that can be displayed or used to trigger actions (e.g., fix auto-suspend, identify low-util warehouses).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` latency (up to ~8 hours) means near-real-time dashboards will be misleading. | Users might make incorrect decisions on partial data. | Display “data as of” watermark; compare max `start_time` present vs now. [Snowflake Docs] |
| <~100ms queries are excluded from query attribution. | Execution credits by query/user/tag will undercount highly chatty workloads. | Measure “attributed coverage” = sum(exec credits)/metered credits; monitor drift. [Snowflake Docs] |
| Proportional idle allocation can be “unfair” for bursty users (idle caused by one team is spread across all activity in window). | Chargeback disputes. | Offer alternative allocation heuristics (e.g., allocate idle to last-query tag before suspend) as an optional advanced mode (requires more event modeling). |
| Third-party reports of possible mismatches/oddities in `QUERY_ATTRIBUTION_HISTORY` attribution. | Incorrect showback if taken as ground truth. | Always reconcile to `WAREHOUSE_METERING_HISTORY`; open support ticket if persistent mismatch. [Greybeam] |

## Links & Citations

1. Snowflake Docs: QUERY_ATTRIBUTION_HISTORY (usage notes, exclusions, latency) — https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. Snowflake Docs: Attributing cost (tagging strategy + proportional idle distribution examples) — https://docs.snowflake.com/en/user-guide/cost-attributing
3. Snowflake Docs: METERING_HISTORY (hourly credits by service_type) — https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Snowflake Docs: WAREHOUSE_METERING_HISTORY table function (6 month note + privileges) — https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
5. Snowflake Docs: Account Usage overview (general reference; reconciliation notes incl. UTC when reconciling against ORG_USAGE) — https://docs.snowflake.com/en/sql-reference/account-usage
6. Greybeam: Deep dive on query cost attribution + suggested validation against metering — https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a “coverage & reconciliation” model/table in the app that stores (per day): metered warehouse credits vs sum(attributed compute) vs delta (idle/unattributed).
- Research whether `WAREHOUSE_UTILIZATION` (mentioned by Greybeam) is now generally available and/or what enables it; evaluate if it improves idle attribution quality.
- Decide a default chargeback policy: execution-only vs proportional-idle (document the tradeoffs).