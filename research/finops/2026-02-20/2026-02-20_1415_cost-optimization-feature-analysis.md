# Research: FinOps - 2026-02-20
**Time:** 1415 UTC
**Topic:** Snowflake FinOps Cost Optimization & Native App Feature Analysis
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **Warehouse sizing is the primary cost lever.** Snowflake encourages rightsizing—start small and scale up. Oversized warehouses burn credits without proportional performance gains. Grouping similar workloads in the same virtual warehouse prevents over-provision.
2. **Query tagging enables granular cost attribution.** Query tags allow BYOK (Bring Your Own Key) style cost tracking per team, project, or workload. This is essential for chargeback/showback models in FinOps.
3. **Time-travel and storage costs are often overlooked.** Transient tables (no time-travel) vs permanent tables (infinite time-travel default) can significantly reduce storage costs. Zero-copy cloning is preferred for dev/test environments.
4. **Snowpark Container Services (SPCS) allows custom container workloads inside Snowflake.** Snowpark Python supports Python 3.9-3.13, with Snowpark pandas supporting 3.9-3.11. UDF development requires local conda environment matching Snowflake channel for best experience.
5. **Snowpipe Streaming and Kafka ingest patterns exist for cost-efficient ingestion.** The Java Ingest SDK supports both Snowpipe (file-based) and Snowpipe Streaming (row-based) APIs for programmatic ingestion via RSA key-pair auth.

## Snowflake Objects & Data Sources
| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | ACCOUNT_USAGE | Snowflake | Credit consumption by warehouse |
| QUERY_HISTORY | ACCOUNT_USAGE | Snowflake | Granular query-level cost attribution |
| TABLE_STORAGE_METRICS | ACCOUNT_USAGE | Snowflake | Storage cost tracking per table |
| AUTOMATIC_CLUSTERING_HISTORY | ACCOUNT_USAGE | Snowflake | Clustering service costs |
| SEARCH_OPTIMIZATION_HISTORY | ACCOUNT_USAGE | Snowflake | Search optimization costs |
| SNOWPIPE_USAGE_HISTORY | ACCOUNT_USAGE | Snowflake | Snowpipe pipe load costs |
| REPLICATION_USAGE_HISTORY | ACCOUNT_USAGE | Snowflake | Replication (cross-region) costs |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level (not yet available for most views)
- `INFO_SCHEMA` = Database-level (limited cost visibility)

## MVP Features Unlocked
*PR-sized ideas that can be shipped based on these findings.*

1. **Smart Warehouse Right-Sizing Advisor:** Query `WAREHOUSE_METERING_HISTORY` + `QUERY_HISTORY` to recommend warehouse size downgrades for underutilized warehouses (avg utilization <60%). PR includes a SQL view + Streamlit UI widget showing recommendations with confidence scores.

2. **Query Tagging Compliance Dashboard:** Detect untagged queries above a credit threshold (e.g., >10 credits) using `QUERY_HISTORY`. Show compliance % and untagged query volume. PR includes daily audit report + Slack/email integration.

3. **Time-Travel Storage Optimizer:** Scan `TABLE_STORAGE_METRICS` to identify large permanent tables with high time-travel retention but low query frequency. Recommend conversion to transient tables with estimated savings. PR includes SQL procedure + dry-run mode.

4. **SPCS Cost Estimator:** Input expected compute/memory/storage needs for a Snowpark Container Service. Output estimated credits/hour vs equivalent warehouse. PR includes a Python module using Snowflake's pricing APIs.

5. **Replicated Table Audit:** Cross-reference `REPLICATION_USAGE_HISTORY` with last access timestamps to identify over-replicated tables. PR includes weekly automated report with recommendations to suspend replication.

## Concrete Artifacts

### Artifact 1: Untagged Query Detection (SQL Draft)
```sql
-- Detect expensive untagged queries from last 7 days
SELECT 
    USER_NAME,
    WAREHOUSE_NAME,
    QUERY_TEXT,
    EXECUTION_TIME_MS / 1000.0 / 3600.0 * WAREHOUSE_SIZE_XS_CRF AS EST_CREDITS,
    TOTAL_ELAPSED_TIME,
    QUERY_TAG
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
    AND QUERY_TAG IS NULL
    AND DATABASE_NAME IS NOT NULL  -- Filter out system queries
    AND (TOTAL_ELAPSED_TIME / 1000.0 / 3600.0) > 0.1  -- >6 min runtime
ORDER BY EST_CREDITS DESC
LIMIT 100;
```

### Artifact 2: Warehouse Utilization Metrics (SQL Draft)
```sql
-- Calculate average utilization per warehouse over last 7 days
SELECT 
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    SUM(QUERY_EXECUTION_TIME) / 3600.0 AS QUERY_HOURS,
    SUM(WAREHOUSE_ACTIVE_TIME) / 3600.0 AS ACTIVE_HOURS,
    100 * QUERY_HOURS / NULLIF(ACTIVE_HOURS, 0) AS UTILIZATION_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY USING(WAREHOUSE_ID)
WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY UTILIZATION_PCT ASC;
```

## Risks / Assumptions
| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE` views have up to 45 minute latency | Dashboards show stale data for recent activity | Query most recent available timestamp |
| Snowflake pricing model changes for SPCS | Cost estimator becomes inaccurate | Monitor pricing announcements |
| Incomplete query tags (e.g., typos) | False negatives in compliance reports | Normalize tags before comparison |
| Warehouse auto-resume behavior affects utilization calc | Misleading right-sizing recommendations | Adjust threshold for auto-suspending warehouses |

## Links & Citations
1. **Monte Carlo Data - 5 Snowflake Cost Optimization Techniques:** https://www.montecarlodata.com/blog-snowflake-cost-optimization/ - Warehouse sizing, query optimization, table optimization best practices
2. **Snowflake Ingest Service Java SDK:** https://github.com/snowflakedb/snowflake-ingest-java - Snowpipe/Snowpipe Streaming patterns for cost-efficient ingestion
3. **Snowpark Python GitHub Repository:** https://github.com/snowflakedb/snowpark-python - Supported Python versions, SPCS integration patterns

## Next Steps / Follow-ups
- Validate SQL draft performance on large `QUERY_HISTORY` (millions of rows)
- Research Snowflake's new `COST_LIMIT` feature for warehouse budget controls (recent release)
- Check SPCS GPU pricing vs. warehouse pricing for ML workloads
- Review Snowflake's March 2026 release notes for new cost management APIs

---

**PR Recommendation:** *Smart Warehouse Right-Sizing Advisor* is the highest-value/lowest-risk first PR. It provides immediate cost savings visibility, uses only existing `ACCOUNT_USAGE` views (no new permissions needed), and can be implemented as pure SQL + Streamlit UI. Estimated dev time: 2-3 days. Ship this first to validate the FinOps data foundation before building more complex features.
