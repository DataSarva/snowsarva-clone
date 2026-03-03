# Research: FinOps - 2026-03-03

**Time:** 20:48 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credit usage** per warehouse for the **last 365 days**, including `CREDITS_USED` (compute + cloud services) plus separate `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`. The view also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributed to query execution) and explicitly excludes warehouse idle time from that attributed metric.  
   (Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`)
2. The credits shown in `WAREHOUSE_METERING_HISTORY.CREDITS_USED` do **not** account for Snowflake’s cloud services billing adjustment; the docs state the value “may be greater than the credits that are billed” and recommend using `METERING_DAILY_HISTORY` to determine actually billed credits.  
   (Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`; also see overall cost docs for cloud services charging behavior)
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `WAREHOUSE_NAME`, `QUERY_TAG`, timing and queueing metrics, and a `CREDITS_USED_CLOUD_SERVICES` field (with the same “consumed vs billed” caveat). This supports a query-level attribution layer (with limitations and latency).  
   (Source: Snowflake docs for `QUERY_HISTORY`)
4. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` records **direct** tag ↔ object associations (does **not** include tag inheritance) and can be used to map tags (e.g., `cost_center`, `team`) to objects for cost attribution.  
   (Source: Snowflake docs for `TAG_REFERENCES`)
5. Resource Monitors can **help control costs for warehouses** by notifying and/or suspending user-managed warehouses when thresholds are reached, but they **do not apply to serverless features / AI services**; Snowflake recommends Budgets for those. Resource monitor credit usage also includes cloud services credits without accounting for the “daily 10% adjustment.”  
   (Source: Snowflake docs for Resource Monitors)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse; latency up to ~180 min (cloud services up to 6h). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (no idle). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query metadata incl. `QUERY_TAG`, `WAREHOUSE_NAME`, timings, bytes scanned, queueing. Suitable for drilldown, not “perfect billing”. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag associations; no inheritance; includes `OBJECT_ID`, `DOMAIN`, `TAG_NAME`, `TAG_VALUE`. |
| Resource Monitors (`CREATE RESOURCE MONITOR` etc.) | Object | N/A | Warehouse-only enforcement; not serverless/AI; cloud services adjustment caveat. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle burn leaderboard**: For each warehouse, compute hourly/daily `idle_credits = CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES` and trend it; surface “top idle spenders” and recommended auto-suspend tuning.
2. **Cloud services ratio alerts (warehouse)**: Track `CREDITS_USED_CLOUD_SERVICES / CREDITS_USED` by warehouse-hour/day and flag abnormal spikes (often metadata-heavy workloads, compilation churn, or heavy control-plane usage).
3. **Tag-based allocation (warehouse-level)**: Join `WAREHOUSE_METERING_HISTORY` to `TAG_REFERENCES` (warehouse domain) to rollup credits by `cost_center`/`team` tags. Explicitly label as “consumed credits (unadjusted)” to avoid billing confusion.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Hourly warehouse credits + idle credits + tag rollups (draft)

```sql
-- Purpose:
--   Build an hourly fact table for warehouse cost intelligence:
--   - consumed credits (compute + cloud services)
--   - compute credits attributed to queries (excludes idle)
--   - derived idle credits
--   - tag dimensions (e.g., cost_center/team) for allocation
--
-- Caveats:
--   - WAREHOUSE_METERING_HISTORY credits are *consumed* and may exceed *billed* credits
--     due to cloud services billing adjustment; use METERING_DAILY_HISTORY for billed.
--   - TAG_REFERENCES contains only direct tag links (no inheritance).
--
-- Assumption (validate in-account):
--   For DOMAIN='WAREHOUSE', TAG_REFERENCES.OBJECT_ID matches WAREHOUSE_METERING_HISTORY.WAREHOUSE_ID.

create or replace table FINOPS_MART.FACT_WAREHOUSE_CREDITS_HOURLY as
with wh as (
  select
    start_time,
    end_time,
    warehouse_id,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) as idle_credits_compute
  from snowflake.account_usage.warehouse_metering_history
  where start_time >= dateadd('day', -90, current_timestamp())
),
-- pivot a small set of tags into columns (extend as needed)
wh_tags as (
  select
    object_id as warehouse_id,
    max(iff(tag_name ilike 'COST_CENTER', tag_value, null)) as cost_center,
    max(iff(tag_name ilike 'TEAM', tag_value, null)) as team
  from snowflake.account_usage.tag_references
  where domain = 'WAREHOUSE'
    and object_deleted is null
  group by 1
)
select
  wh.start_time,
  wh.end_time,
  wh.warehouse_id,
  wh.warehouse_name,
  t.cost_center,
  t.team,
  wh.credits_used,
  wh.credits_used_compute,
  wh.credits_used_cloud_services,
  wh.credits_attributed_compute_queries,
  wh.idle_credits_compute
from wh
left join wh_tags t
  on t.warehouse_id = wh.warehouse_id;

-- Example rollup: daily spend by cost_center
select
  date_trunc('day', start_time) as day,
  cost_center,
  sum(credits_used) as credits_used_consumed,
  sum(idle_credits_compute) as idle_credits_compute_consumed
from FINOPS_MART.FACT_WAREHOUSE_CREDITS_HOURLY
group by 1,2
order by day desc, credits_used_consumed desc;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES.OBJECT_ID` join key for warehouses may not match `WAREHOUSE_ID` (or needs different join logic). | Wrong attribution by tags (silent misallocation). | Run a small spot-check query in the target account: pick a tagged warehouse and verify `OBJECT_ID` equals `WAREHOUSE_ID` from `WAREHOUSE_METERING_HISTORY` (or join via `WAREHOUSE_NAME` if safe). |
| Account Usage view latencies (hours) can make near-real-time dashboards misleading. | Delayed alerting / false negatives for “today”. | In app UI, label freshness (max `END_TIME`) and add “data latency” banner; optionally blend with `INFORMATION_SCHEMA` where available (time-limited). |
| Consumed credits vs billed credits confusion (cloud services adjustment; doc says `WAREHOUSE_METERING_HISTORY` may exceed billed). | Users distrust the app when numbers don’t reconcile to invoice. | Provide a toggle/metric for “consumed (raw)” vs “billed (daily metering)” and explain the adjustment in a tooltip/ADR. |
| Resource Monitors don’t govern serverless/AI spend. | Gaps in cost control if users assume full coverage. | In recommendations, distinguish “warehouse enforcement” vs “budgets for serverless/AI”. |

## Links & Citations

1. Snowflake docs — `WAREHOUSE_METERING_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake docs — `QUERY_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. Snowflake docs — `TAG_REFERENCES` view: https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
4. Snowflake docs — Understanding overall cost (compute/storage/data transfer; cloud services charging behavior): https://docs.snowflake.com/en/user-guide/cost-understanding-overall
5. Snowflake docs — Working with Resource Monitors (warehouse-only; cloud services adjustment caveat): https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Validate the **warehouse tag join key** assumption in a real account (warehouse object id mapping).
- Add a companion daily table built from `METERING_DAILY_HISTORY` to present a “billed credits” view alongside “consumed credits”.
- Extend tag pivoting: support arbitrary tag keys (dynamic pivot) or a normalized tag dimension table for flexible filtering in the Native App UI.
