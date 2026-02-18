# Research: FinOps - 2026-02-18

**Time:** 14:01 UTC  
**Topic:** Warehouse Cost Intelligence and Idle Cost Detection  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **Warehouses bill by the second with a 60-second minimum** - As shown in the warehouse billing table, each time a warehouse starts, it incurs a minimum 60-second charge. For short queries on larger warehouses, this minimum can dominate actual compute costs.

2. **Idle time is measurable via WAREHOUSE_METERING_HISTORY** - The view exposes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credit usage for actual queries) which can be subtracted from `CREDITS_USED_COMPUTE` to calculate idle cost. Per docs: "Warehouse idle time is not included in the CREDITS_ATTRIBUTED_COMPUTE_QUERIES column."

3. **QUERY_HISTORY provides per-query attribution** - Columns like `WAREHOUSE_SIZE`, `WAREHOUSE_TYPE`, `CLUSTER_NUMBER`, `EXECUTION_TIME`, `COMPILATION_TIME`, and various `QUEUED_*_TIME` metrics allow fine-grained attribution of query costs.

4. **METERING_DAILY_HISTORY reconciles cloud services adjustments** - Cloud services credits are adjusted (often reduced) daily via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` - the billed amount differs from raw usage.

5. **Multi-cluster warehouses scale credit usage linearly** - Running 2 clusters of a warehouse for 1 hour costs double the credits of 1 cluster.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | 3h latency. Key for idle cost detection. |
| QUERY_HISTORY | View | ACCOUNT_USAGE | Per-query cost attribution. 100K char text limit. |
| METERING_DAILY_HISTORY | View | ACCOUNT_USAGE | Cloud services rebate/reconciliation |
| WAREHOUSE_METERING | Service | ORG_USAGE | Use UTC timezone for reconciliation |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle Warehouse Detection Dashboard** - Native App page showing warehouse idle time %, cost of idle time, and recommendations for auto-suspend threshold tuning. PR-sized: Single Streamlit/React component + SQL view.

2. **Query-Level Cost Attribution** - Link QUERY_HISTORY with WAREHOUSE_METERING_HISTORY to attribute actual dollar costs to users/teams/projects via query_tag. PR-sized: SQL UDF + reporting view.

3. **Warehouse Right-Size Recommendation Engine** - Analyze query duration vs warehouse size to recommend downsizing opportunities. PR-sized: SQL stored procedure + recommendations table.

4. **Auto-Suspend Optimizer** - Train on actual query patterns to recommend optimal auto-suspend thresholds (balance cold-start cost vs idle cost). PR-sized: Snowpark ML model + UI for approvals.

5. **Multi-cluster Efficiency Report** - Identify over-provisioned multi-cluster warehouses by analyzing queuing patterns vs cluster count. PR-sized: Scheduled task + dashboard view.

## Concrete Artifacts

### Idle Cost Calculation SQL
```sql
-- Idle cost per warehouse over last 7 days
SELECT
    warehouse_name,
    SUM(credits_used_compute) AS total_compute_credits,
    SUM(credits_attributed_compute_queries) AS query_attributed_credits,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits,
    ROUND(
        (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) / 
        NULLIF(SUM(credits_used_compute), 0) * 100, 
        2
    ) AS idle_pct,
    -- Assuming $3/credit, adjust for your rate
    ROUND((SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) * 3.0, 2) AS idle_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name
HAVING idle_credits > 0
ORDER BY idle_credits DESC;
```

### Query Cost Attribution SQL
```sql
-- Attribute cost to query_tags (requires tag-based allocation strategy)
WITH warehouse_costs AS (
    SELECT 
        DATE(start_time) AS usage_date,
        warehouse_name,
        SUM(credits_used_compute) AS total_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD(day, -30, CURRENT_DATE())
    GROUP BY usage_date, warehouse_name
),
query_weights AS (
    SELECT 
        DATE(start_time) AS usage_date,
        warehouse_name,
        query_tag,
        SUM(execution_time) AS total_exec_time_ms,
        COUNT(*) AS query_count
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD(day, -30, CURRENT_DATE())
      AND warehouse_name IS NOT NULL
    GROUP BY usage_date, warehouse_name, query_tag
),
query_allocation AS (
    SELECT 
        qw.usage_date,
        qw.warehouse_name,
        qw.query_tag,
        qw.query_count,
        qw.total_exec_time_ms,
        wc.total_credits,
        ROUND(
            qw.total_exec_time_ms / 
            NULLIF(SUM(qw.total_exec_time_ms) OVER (PARTITION BY qw.usage_date, qw.warehouse_name), 0) * 
            wc.total_credits, 
            4
        ) AS allocated_credits
    FROM query_weights qw
    JOIN warehouse_costs wc 
        ON qw.usage_date = wc.usage_date 
        AND qw.warehouse_name = wc.warehouse_name
)
SELECT 
    query_tag,
    SUM(allocated_credits) AS total_allocated_credits,
    ROUND(SUM(allocated_credits) * 3.0, 2) AS estimated_cost_usd -- adjust credit rate
FROM query_allocation
GROUP BY query_tag
ORDER BY estimated_cost_usd DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Query time != compute cost perfectly | Medium | Test attribution accuracy against actual billing |
| QUERY_TAG adoption inconsistent | High | Build discovery UI; fallback to user/warehouse attribution |
| Multi-cluster auto-scaling affects idle calc | Medium | Test with multi-cluster warehouses specifically |
| Credit rate varies by contract | Low | Make credit rate configurable per deployment |

## Links & Citations

1. Warehouse sizing, credit consumption, and auto-suspend: https://docs.snowflake.com/en/user-guide/warehouses-overview
2. WAREHOUSE_METERING_HISTORY view and idle cost calculation: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. QUERY_HISTORY view for per-query attribution: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. METERING_DAILY_HISTORY and cloud services reconciliation: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

## Next Steps / Follow-ups

- [ ] Validate idle cost SQL against actual invoices for test account
- [ ] Design notification system for high-idle warehouses (Slack/email integration)
- [ ] Research Snowflake's Cost Management UI for feature parity opportunities
- [ ] Build POC for warehouse right-sizing recommendations

---
*Research node: snowflake-finops-native-app | Session: 2026-02-18_1401*
