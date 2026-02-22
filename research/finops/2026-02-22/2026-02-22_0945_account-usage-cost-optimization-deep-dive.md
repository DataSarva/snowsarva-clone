# Research: FinOps - 2026-02-22

**Time:** 2026-02-22T09:45:00 UTC
**Topic:** Snowflake FinOps Cost Optimization
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Warehouse metering granularity is hourly**, but idle time calculations require manual subtraction of `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` from `CREDITS_USED_COMPUTE` to isolate idle costs.

2. **ACCOUNT_USAGE views have 45 minutes to 3 hours latency** for historical data, with data retained for 1 year. Info Schema has real-time data but only 7 days to 6 months retention.

3. **METERING_HISTORY contains 30+ service types** beyond warehouse metering, including Snowpark Container Services, Serverless Tasks, Snowpipe, Auto-clustering, and Query Acceleration Service.

4. **Cloud services credits in METERING_HISTORY have 6-hour latency** vs. 3 hours for compute credits, complicating real-time reconciliation.

5. **Warehouse idle time is NOT automatically exposed** - must be calculated as the difference between total compute credits and query-attributed credits.

6. **QUERY_HISTORY now includes `query_load_percent`** showing the approximate percentage of active compute resources used per query - useful for identifying underutilized warehouses.

7. **Query hashes (`query_hash` and `query_parameterized_hash`)** now exist in QUERY_HISTORY enabling cache analysis and query pattern analysis across historical data.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `WAREHOUSE_METERING_HISTORY` | Historical | `ACCOUNT_USAGE` | 3 hour latency, 1 year retention. Core view for warehouse cost tracking. |
| `METERING_HISTORY` | Historical | `ACCOUNT_USAGE` | 3 hour latency (6h for cloud services). Aggregated credit consumption by service type. |
| `QUERY_HISTORY` | Historical | `ACCOUNT_USAGE` | 45 min latency. Detailed query-level metrics including `credits_used_cloud_services`. |
| `LOGIN_HISTORY` | Historical | `ACCOUNT_USAGE` | 2 hour latency. User session and security context. |
| `AUTOMATIC_CLUSTERING_HISTORY` | Historical | `ACCOUNT_USAGE` | 3 hour latency. Credit consumption for reclustering operations. |
| `SNOWPARK_CONTAINER_SERVICES_HISTORY` | Historical | `ACCOUNT_USAGE` | 3 hour latency. SPCS compute consumption tracking. |
| `STORAGE_USAGE` | Historical | `ACCOUNT_USAGE` | 2 hour latency. Combined table and stage storage metrics. |
| `DATABASE_STORAGE_USAGE_HISTORY` | Historical | `ACCOUNT_USAGE` | 3 hour latency. Storage per database over time. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata in SNOWFLAKE db
- `ORG_USAGE` = Organization-level views (not covered here)
- `INFO_SCHEMA` = Database-level real-time views

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle Warehouse Detector:** Query `WAREHOUSE_METERING_HISTORY` weekly to identify warehouses with >30% idle compute credits and recommend sizing changes or auto-suspend adjustments.

2. **Services Breakdown Dashboard:** Aggregate `METERING_HISTORY` by `SERVICE_TYPE` to show customers their consumption mix across warehouses, Snowpipe, SPCS, and serverless features.

3. **Query Performance Baseliner:** Use `QUERY_HISTORY.query_hash` to group similar queries over time and detect performance regressions by tracking `execution_time` trends.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Warehouse Idle Cost Calculator

```sql
-- Calculate idle time cost for each warehouse over last 7 days
-- Idle cost = compute credits - credits attributed to actual queries

SELECT
    warehouse_name,
    SUM(credits_used_compute) AS total_compute_credits,
    SUM(credits_attributed_compute_queries) AS query_attributed_credits,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits,
    ROUND(
        (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) 
        / NULLIF(SUM(credits_used_compute), 0) * 100, 
        2
    ) AS idle_percentage,
    -- Cost at $2/credit (multiply by actual rate)
    ROUND(
        (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) * 2, 
        2
    ) AS estimated_idle_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('days', -7, CURRENT_DATE())
GROUP BY warehouse_name
HAVING SUM(credits_used_compute) > 0
ORDER BY idle_credits DESC;
```

### Daily Services Breakdown View

```sql
-- Create view for daily service type consumption
-- Useful for trend analysis and anomaly detection

CREATE OR REPLACE VIEW DAILY_SERVICE_CONSUMPTION AS
SELECT
    DATE(start_time) AS usage_date,
    service_type,
    SUM(credits_used) AS total_credits,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_services_credits,
    COUNT(DISTINCT entity_id) AS unique_entities
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('days', -90, CURRENT.DATE())
GROUP BY 1, 2
ORDER BY usage_date DESC, total_credits DESC;
```

### Top Expensive Queries by Hash

```sql
-- Identify most expensive recurring query patterns
-- Group by parameterized hash to account for different bind values

SELECT
    query_parameterized_hash,
    ANY_VALUE(query_text) AS sample_query_text,
    COUNT(*) AS execution_count,
    SUM(credits_used_cloud_services) AS total_cloud_credits,
    ROUND(AVG(execution_time / 1000), 2) AS avg_exec_time_seconds,
    ROUND(AVG(total_elapsed_time / 1000), 2) AS avg_total_time_seconds,
    ROUND(AVG(bytes_scanned / 1024 / 1024 / 1024), 2) AS avg_gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('days', -30, CURRENT_DATE())
  AND execution_status = 'SUCCESS'
  AND query_parameterized_hash IS NOT NULL
GROUP BY query_parameterized_hash
HAVING COUNT(*) > 10
ORDER BY total_cloud_credits DESC
LIMIT 50;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| API key for Parallel AI was invalid | Medium | Could only use web_fetch; Parallel API would enable deeper multi-source extraction | 
| ACCOUNT_USAGE latency (3h) makes it unsuitable for real-time alerting | Medium | Need to build alerting on INFO_SCHEMA for low-latency use cases |
| Cloud service credits reconciliation varies by service type | Low | METERING_DAILY_HISTORY view is the canonical source for actual billing |
| User timezone affects WAREHOUSE_METERING_HISTORY | Low | Convert to UTC before analysis (docs recommend UTC for cross-view reconciliation) |

## Links & Citations

1. [Snowflake ACCOUNT_USAGE Overview](https://docs.snowflake.com/en/sql-reference/account-usage) - Complete list of views and their latencies
2. [WAREHOUSE_METERING_HISTORY Reference](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) - Hourly credit usage with idle time calculation
3. [METERING_HISTORY Reference](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history) - Multi-service credit consumption tracking
4. [QUERY_HISTORY Reference](https://docs.snowflake.com/en/sql-reference/account-usage/query_history) - Query-level metrics including query_hash and credits

## Next Steps / Follow-ups

- [ ] Fetch ORG_USAGE documentation for cross-account FinOps analytics
- [ ] Research Snowflake Native App pricing/monetization model (API not available during this session)
- [ ] Investigate SNOWFLAKE database roles (OBJECT_VIEWER, USAGE_VIEWER, etc.) for least-privilege access patterns
- [ ] Create materialized view patterns for daily cost aggregation to reduce query costs

---
*Research conducted 2026-02-22. Sources verified at fetch time.*
