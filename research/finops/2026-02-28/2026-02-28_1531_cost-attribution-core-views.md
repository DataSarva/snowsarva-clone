# Research: FinOps - 2026-02-28

**Time:** 15:31 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution core views)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for up to the last **365 days**, including compute and cloud-services components, plus a `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` metric that excludes idle time. It has documented latency up to **180 minutes**, and `CREDITS_USED_CLOUD_SERVICES` can lag up to **6 hours**.  
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage at the account level (last **365 days**) broken down by `SERVICE_TYPE` / `ENTITY_TYPE` / `NAME`, with similar latency notes (up to **180 minutes**, cloud services up to **6 hours**, and Snowpipe Streaming up to **12 hours**).  
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `QUERY_TAG`, `WAREHOUSE_NAME`, timing (start/end/elapsed), and `CREDITS_USED_CLOUD_SERVICES` per statement (not adjusted for billed cloud services) which can be used for query-level investigation and tagging-based attribution patterns.
4. Snowflake warehouse compute billing is **per-second with a 60-second minimum** each time a warehouse starts/resumes; suspending/resuming within the first minute can create multiple 1-minute minimum charges.  
5. Cloud services billing is subject to a **daily adjustment**: cloud services are charged only when daily consumption exceeds **10%** of daily warehouse usage; the adjustment is calculated daily in **UTC**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; contains `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; notes include idle-time example query and reconciliation guidance (set session timezone to UTC when reconciling with ORG_USAGE). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account credits by `SERVICE_TYPE` / `ENTITY_TYPE` / `NAME`; lists many serverless/feature service types (e.g., SEARCH_OPTIMIZATION, AUTO_CLUSTERING, SERVERLESS_TASK, SNOWPARK_CONTAINER_SERVICES). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-statement history incl. `QUERY_TAG`, `ROLE_NAME`, `ROLE_TYPE`, `WAREHOUSE_NAME`, timings, bytes scanned/written, and `CREDITS_USED_CLOUD_SERVICES` (not adjusted). |
| (Referenced) `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned as the place to determine **credits actually billed** after cloud-services adjustment (not deep-read in this session; treat as follow-up validation). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Hourly Warehouse Idle-Cost Lens:** Compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` per warehouse-hour, and surface top idle offenders + trendlines (directly supported by `WAREHOUSE_METERING_HISTORY`).
2. **Service-Type Cost Map:** A single “where did credits go?” view using `METERING_HISTORY` to break spend into warehouse metering vs serverless features (auto clustering, search optimization, tasks, etc.).
3. **Query Tag Governance Loop:** Detect missing/low-quality `QUERY_TAG` coverage using `QUERY_HISTORY` and enforce via recommended session/query-tag patterns (app guidance) + attribution rollups by tag.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: hourly warehouse idle + attributed credits rollup

```sql
-- Goal:
--   Produce an hourly warehouse rollup that highlights idle vs attributed compute credits.
-- Notes:
--   Source view is hourly and has documented latency.
--   This uses credits "used" metrics (not necessarily "billed" after cloud-services adjustment).

create or replace view FINOPS.MONITORING.WAREHOUSE_HOURLY_CREDITS as
select
  start_time,
  end_time,
  warehouse_name,
  sum(credits_used_compute)                         as credits_used_compute,
  sum(credits_attributed_compute_queries)           as credits_attributed_compute_queries,
  -- idle compute = warehouse ran but queries weren't executing
  sum(credits_used_compute) - sum(credits_attributed_compute_queries) as credits_idle_compute,
  sum(credits_used_cloud_services)                  as credits_used_cloud_services,
  sum(credits_used)                                 as credits_used_total
from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
where start_time >= dateadd('day', -30, current_timestamp())
group by 1,2,3;
```

### SQL draft: query-tag coverage by warehouse/day (investigative)

```sql
-- Goal:
--   Understand QUERY_TAG coverage and link it to warehouse usage.
-- Notes:
--   QUERY_HISTORY includes query_tag and warehouse_name, but warehouse-hour billing includes idle time.

create or replace view FINOPS.MONITORING.QUERY_TAG_COVERAGE_DAILY as
select
  date_trunc('day', start_time) as day,
  warehouse_name,
  count(*) as queries,
  count_if(query_tag is null or trim(query_tag) = '') as untagged_queries,
  untagged_queries / nullif(queries, 0) as untagged_ratio
from SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
where start_time >= dateadd('day', -30, current_timestamp())
  and warehouse_name is not null
group by 1,2;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Using `CREDITS_USED*` can differ from **credits billed** due to cloud-services adjustment; warehouse metering docs explicitly note this. | Attribution may not reconcile to invoice without additional steps. | Deep-read and incorporate `METERING_DAILY_HISTORY` into reconciliation logic (follow-up). |
| View latencies (3–6+ hours) mean near-real-time dashboards may be misleading. | Alerts may fire late; “today” numbers can be incomplete. | Implement “data freshness” watermarking based on max `END_TIME` observed; document SLAs. |
| Query-level attribution cannot naturally account for warehouse **idle** time without a policy choice. | Tag-based rollups will undercount vs warehouse metering unless idle is allocated. | Offer explicit idle allocation policy options (e.g., to warehouse owner tag, evenly across queries, or leave unallocated). |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/user-guide/cost-understanding-compute
5. https://docs.snowflake.com/en/user-guide/cost-understanding-overall

## Next Steps / Follow-ups

- Deep-read `METERING_DAILY_HISTORY` and document a concrete reconciliation path: *warehouse hourly used* → *daily billed* (cloud-services adjustment in UTC).
- Add an ADR for idle-credit allocation policy options and default behavior in the FinOps Native App.
- Extend service-type mapping to distinguish warehouse metering vs serverless features for a “top drivers” dashboard.
