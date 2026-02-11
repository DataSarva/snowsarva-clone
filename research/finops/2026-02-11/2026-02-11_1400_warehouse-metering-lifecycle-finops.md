# Research: FinOps - 2026-02-11

**Time:** 14:00 UTC  
**Topic:** Warehouse Metering and Cost Control Capabilities for Snowflake FinOps Native App  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake ACCOUNT_USAGE views (like WAREHOUSE_METERING_HISTORY, WAREHOUSE_EVENTS_HISTORY) provide deep operational observability with up to 3 hours latency, enabling near-real-time cost tracking with 365-day retention.

2. WAREHOUSE_METERING_HISTORY exposes CREDITS_ATTRIBUTED_COMPUTE_QUERIES _distinguishing actual query execution credits from warehouse idle time—critical for idle cost optimization recommendations.

3. WAREHOUSE_EVENTS_HISTORY tracks lifecycle events (resume, suspend, resize, auto-suspend/resume) with EVENT_REASON and EVENT_STATE granularity, enabling detailed efficiency analysis.

4. CREDITS_USED_CLOUD_SERVICES has 6-hour latency (vs 3h for compute), requiring hybrid data strategy for complete cost attribution views.

5. Resource monitors support up to 5 notification thresholds and can auto-suspend warehouses when limits are hit—native cost control infrastructure without custom code.

6. Snowflake budgets (newer feature) support monthly spending limits across warehouses and serverless features with webhook/SNS/email notifications—more comprehensive than resource monitors alone.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Latency | Notes |
|-------------|------|--------|---------|-------|
| WAREHOUSE_METERING_HISTORY | Historical usage | ACCOUNT_USAGE | 3h (6h for cloud services) | All credit types incl. idle attribution |
| WAREHOUSE_EVENTS_HISTORY | Event audit | ACCOUNT_USAGE | 3h | Resize, suspend, resume events |
| WAREHOUSE_LOAD_HISTORY | Workload analysis | ACCOUNT_USAGE | 3h | 5-min intervals, queue/blocked metrics |
| METERING_DAILY_HISTORY | Billing reconciliation | ACCOUNT_USAGE | 1h | Adjusted credits (cloud services excluded) |
| ACCESS_HISTORY | Object access | ACCOUNT_USAGE | 3h | Enterprise only, 1yr retention |

**Legend:**
- `ACCOUNT_USAGE` = Snowflake metadata schema (all accounts)
- `ORGANIZATION_USAGE` = Org-level (requires ACCOUNTADMIN)
- `INFORMATION_SCHEMA` = Real-time but limited retention

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle Cost Report** - Weekly automated identifying warehouses with high idle % (CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES), recommending auto-suspend tuning or downsizing.

2. **Warehouse Events Timeline** - Viz of resize/suspend/resume events correlated with usage spikes, enabling ops teams to diagnose why costs jumped.

3. **Budget vs Actual Alert** - Integration with Snowflake Budgets API to surface budget burn rate predictions and trigger proactive Slack/PagerDuty notifications before thresholds.

4. **Query-to-Warehouse Attribution** - Link QUERY_HISTORY to WAREHOUSE_METERING_HISTORY for granular "who spent what on which warehouse last week" stakeholder reports.

5. **Auto-Suspend Optimization Recommendations** - ML suggestions for modifying AUTO_SUSPEND thresholds based on historical query patterns from WAREHOUSE_LOAD_HISTORY gap analysis.

6. **Cost Anomaly Detection** - Spike detection on hourly credit consumption patterns using STATISTICS_EXTRACT function on hourly rollup of WAREHOUSE_METERING_HISTORY.

## Concrete Artifacts

### SQL Draft: Idle Cost Analysis (Last 7 Days)

```sql
-- Query to surface idle cost by warehouse
SELECT
    wmh.WAREHOUSE_NAME,
    DATE_TRUNC('day', wmh.START_TIME) as usage_date,
    SUM(wmh.CREDITS_USED_COMPUTE) as total_compute_credits,
    SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES) as query_attributed_credits,
    SUM(wmh.CREDITS_USED_COMPUTE) - SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES) as idle_credits,
    ROUND(100 * (SUM(wmh.CREDITS_USED_COMPUTE) - SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES)) / 
        NULLIF(SUM(wmh.CREDITS_USED_COMPUTE), 0), 2) as idle_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
WHERE wmh.START_TIME >= DATEADD('day', -7, CURRENT_DATE())
    AND wmh.END_TIME < CURRENT_DATE()
GROUP BY 1, 2
HAVING idle_credits > 0.1
ORDER BY idle_credits DESC;
```

### SQL Draft: Warehouse Events + Usage Correlation

```sql
-- Correlate credit spikes with resize/suspend events
WITH hourly_usage AS (
    SELECT 
        WAREHOUSE_NAME,
        DATE_TRUNC('hour', START_TIME) as hour,
        SUM(CREDITS_USED) as hourly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE())
    GROUP BY 1, 2
),
events AS (
    SELECT 
        WAREHOUSE_NAME,
        DATE_TRUNC('hour', TIMESTAMP) as hour,
        EVENT_NAME,
        EVENT_REASON,
        SIZE
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
    WHERE TIMESTAMP >= DATEADD('day', -7, CURRENT_DATE())
        AND EVENT_NAME IN ('RESIZE_WAREHOUSE', 'WAREHOUSE_RESUME', 'WAREHOUSE_SUSPEND')
)
SELECT 
    u.WAREHOUSE_NAME,
    u.hour,
    u.hourly_credits,
    e.EVENT_NAME,
    e.EVENT_REASON,
    e.SIZE
FROM hourly_usage u
LEFT JOIN events e ON u.WAREHOUSE_NAME = e.WAREHOUSE_NAME AND u.hour = e.hour
WHERE u.hourly_credits > (
    SELECT AVG(hourly_credits) * 2 FROM hourly_usage
)
ORDER BY u.hourly_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ACCOUNT_USAGE latency (3h) makes "real-time" alerting impossible | Native alerting delayed; need hybrid approach | Monitor: validate LAG() =< 3:00 in practice |
| Cloud services credits (auto-included) require special handling in billing reconciliation | Under/over attribution if ignored | Cross-ref METERING_DAILY_HISTORY vs WAREHOUSE_METERING_HISTORY |
| Missing warehouse events (STARTED but never COMPLETED) could corrupt analysis | Event sequence logic must handle orphan events | Audit query for unclosed START events in app logic |
| Enterprise Edition required for some time-series queries (ACCESS_HISTORY) | Feature gated for paid tiers | Check account edition on install |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history - Official WAREHOUSE_METERING_HISTORY documentation with CREDITS_ATTRIBUTED_COMPUTE_QUERIES detail

2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_events_history - Complete EVENT_NAME/EVENT_REASON table and WAREHOUSE_CONSISTENT coalescing logic

3. https://docs.snowflake.com/en/user-guide/cost-controlling - Budgets and resource monitors comparison, webhook support details

4. https://docs.snowflake.com/en/user-guide/warehouses-overview - Warehouse sizes, Gen1/Gen2 credit rates, per-second billing mechanics

5. https://other-docs.snowflake.com/en/connectors - Native Apps connector ecosystem (supports ingestion paths)

## Next Steps / Follow-ups

- [ ] Validate ACCOUNT_USAGE latency in Akhil's test account (verify actual lag vs. documented 3h)
- [ ] Draft PR for idle cost detection native app view
- [ ] Research Snowflake Budgets API availability (is it in preview or GA? undocumented REST?)
- [ ] Explore integration with SnowCLI for automated warehouse resize recommendations

---
