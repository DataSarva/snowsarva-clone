# Research: FinOps - 2026-02-27

**Time:** 03:10 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last 365 days, and its `CREDITS_USED` is the sum of compute + cloud services usage **without** applying the daily “10% cloud services adjustment”; Snowflake explicitly recommends using `METERING_DAILY_HISTORY` to determine credits actually billed.  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`.
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage by `SERVICE_TYPE` and includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`, which together capture the daily application of the cloud services billing adjustment.  
   Source: Snowflake docs for `METERING_DAILY_HISTORY`.
3. Cloud services are billed only when daily cloud services consumption exceeds **10% of daily virtual warehouse usage**; the adjustment is computed **daily in UTC**, and serverless compute does **not** factor into the 10% adjustment.  
   Source: “Understanding billing for cloud services usage” in Snowflake compute cost docs.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes per-query fields such as `WAREHOUSE_NAME`, timing, bytes scanned/spilled, and `CREDITS_USED_CLOUD_SERVICES` (also not billed-adjusted; reconcile billed totals via `METERING_DAILY_HISTORY`).  
   Source: Snowflake docs for `QUERY_HISTORY`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; `CREDITS_USED` may exceed billed due to cloud services adjustment; up to ~3h latency (cloud services column can be up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits by `SERVICE_TYPE`; includes `CREDITS_BILLED` and `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (bill reconciliation primitive). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level workload dimensions (warehouse, time, bytes scanned/spilled, queue times, etc.); includes `CREDITS_USED_CLOUD_SERVICES` but billing adjustment is daily/UTC. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Billed-cost “source of truth” daily ledger**: materialize a daily fact table based on `METERING_DAILY_HISTORY` (`USAGE_DATE`, `SERVICE_TYPE`, `CREDITS_BILLED`) and use it as the single total-cost baseline; layer “explain” breakdowns from warehouse/query views without trying to replace billed totals.
2. **Idle cost detector (hourly, warehouse-level)**: compute idle credits per warehouse using `WAREHOUSE_METERING_HISTORY` (`CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES`) and generate top offenders + auto-suspend recommendations.
3. **Cost reconciliation guardrails**: for any “allocation” report derived from hourly/query views, display a reconciliation panel showing the difference to billed totals (by day) and explain why (cloud services adjustment + view latencies + non-warehouse service types).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Daily billed credits ledger (baseline for FinOps reporting)

```sql
-- Daily billed credits ledger (baseline)
-- Source of truth for credits billed (includes cloud services adjustment).
-- From: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

CREATE OR REPLACE TABLE FINOPS.COST.DAILY_CREDITS_BILLED AS
SELECT
  usage_date::date                 AS usage_date,
  service_type                     AS service_type,
  credits_used_compute             AS credits_used_compute,
  credits_used_cloud_services      AS credits_used_cloud_services,
  credits_adjustment_cloud_services AS credits_adjustment_cloud_services,
  credits_billed                   AS credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -365, CURRENT_DATE());
```

### Artifact: Hourly warehouse idle credits (actionable optimization)

```sql
-- Idle cost approximation per warehouse over last N days
-- From: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

WITH wh AS (
  SELECT
    start_time,
    end_time,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -10, CURRENT_DATE())
    AND end_time < CURRENT_DATE()
)
SELECT
  warehouse_name,
  SUM(credits_used_compute) AS credits_used_compute,
  SUM(credits_attributed_compute_queries) AS credits_attributed_to_queries,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits_compute
FROM wh
GROUP BY 1
ORDER BY idle_credits_compute DESC;
```

### Artifact: Cost allocation model (pseudocode) that reconciles to billed totals

```text
Goal: Attribute daily billed credits (METERING_DAILY_HISTORY) to owners (warehouse/query_tag/etc)
without losing reconciliation.

For each day D:
  total_billed_all_services = sum(METERING_DAILY_HISTORY.credits_billed where usage_date=D)

  # Allocate WAREHOUSE_METERING service_type specifically using warehouse-hourly usage.
  warehouse_billed = sum(credits_billed where service_type like 'WAREHOUSE_METERING%' and usage_date=D)

  # From WAREHOUSE_METERING_HISTORY, compute per-warehouse hourly compute usage (not billed-adjusted).
  wh_hours = all rows where start_time within day D (after setting session TZ to UTC for reconciliation).

  For each warehouse W:
     wh_compute = sum(wh_hours.credits_used_compute for W)
     wh_cloud_services_unadjusted = sum(wh_hours.credits_used_cloud_services for W)

  # Convert unadjusted warehouse usage into shares for allocation
  denom = sum(wh_compute across warehouses)
  For each warehouse W:
     share_W = wh_compute / denom
     allocated_billed_warehouse_credits_W = warehouse_billed * share_W

  # Optional: allocate within a warehouse to query_tag/user/db using QUERY_HISTORY metrics
  For each warehouse W:
     queries = QUERY_HISTORY rows for day D and warehouse=W
     weight per query = (query.execution_time_ms) or (bytes_scanned) or (a learned regression)
     allocate allocated_billed_warehouse_credits_W by query weights

  Remaining billed credits (serverless, AI_SERVICES, etc.)
    are allocated by their own primitives (service-specific views) or left as "unallocated" with clear labeling.

Key: Keep a reconciliation table:
  sum(allocated_credits) + unallocated = total_billed_all_services
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hourly `WAREHOUSE_METERING_HISTORY` totals won’t equal billed totals because of daily cloud services adjustment and non-warehouse service types. | Allocation based purely on hourly views will not reconcile. | Use `METERING_DAILY_HISTORY.CREDITS_BILLED` as baseline and treat hourly views as “explain” / attribution signals. |
| Timezone differences can break reconciliation across `ACCOUNT_USAGE` vs `ORG_USAGE` views. | Daily joins and comparisons may drift by day boundaries. | Follow Snowflake guidance to set session timezone to UTC before reconciling (documented in view usage notes). |
| Query-level “credit” attribution is incomplete for idle time and some overhead. | Query-based cost allocation undercounts true cost. | Use `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` vs `CREDITS_USED_COMPUTE` delta as separate “idle/overhead” bucket. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/user-guide/cost-understanding-compute
4. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Add an `ORG_USAGE` reconciliation lane (org-wide rollups) once we decide whether the Native App targets single account vs org admin; ensure consistent UTC normalization.
- Identify the best “within-warehouse” allocation weights (execution_time vs bytes_scanned vs spill bytes) and validate against representative workloads.
- Implement a small “reconciliation diff” UI component: billed totals vs sum(allocations) vs known non-allocatable buckets.
