# Research: FinOps - 2026-02-06

**Time:** 14:03 UTC  
**Topic:** Snowflake Cost Optimization - Core Account Usage Views & Native App Opportunities  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **WAREHOUSE_METERING_HISTORY contains idle cost calculation capability.** The `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` column isolates query-execution costs from warehouse idle time. Idle cost = `CREDITS_USED_COMPUTE` - `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`.

2. **Org-wide cost visibility requires ORGANIZATION_USAGE schema.** Premium views (e.g., `ACCESS_HISTORY`, `ALERT_HISTORY`, `COMPLETE_TASK_GRAPHS`) are only available in the organization account. Standard org views have 2-24 hour latency.

3. **METERING_HISTORY captures 25+ service types** beyond warehouse compute: AI_SERVICES (Cortex), SNOWPARK_CONTAINER_SERVICES, SERVERLESS_TASK, MATERIALIZED_VIEW, QUERY_ACCELERATION, and more.

4. **ACCOUNT_USAGE data latency varies by view.** Most views: 2 hours. Some (e.g., `WAREHOUSE_METERING_HISTORY` cloud services): up to 6 hours. `READER_ACCOUNT_USAGE`: up to 24 hours.

5. **Snowsight Cost Management UI exposes view queries.** Every dashboard tile has "View query" option - these are canonical SQL templates for that metric.

6. **Native Apps framework supports structured logging via Event Tables.** This enables providers to capture app-specific telemetry for cost attribution and usage analytics.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | Historical usage | ACCOUNT_USAGE | 1-year retention; CREDITS_ATTRIBUTED_COMPUTE_QUERIES for idle analysis |
| METERING_HISTORY | Historical usage | ACCOUNT_USAGE | Aggregates all service types; 25+ services includ. SPCS, Cortex |
| METERING_DAILY_HISTORY | Historical usage | ACCOUNT_USAGE | Billed credits (with cloud services adjustment) |
| ORGANIZATION_USAGE.ACCOUNTS | Object metadata | ORGANIZATION_USAGE | Cross-account spend aggregation |
| ORGANIZATION_USAGE.ACCESS_HISTORY | Premium view | ORGANIZATION_USAGE | Requires org account; query history cross-account |
| INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY | Historical | INFO_SCHEMA | 7-day retention only; no latency |
| SNOWFLAKE.TELEMETRY_DATA_INGEST | Service | METERING_HISTORY | Event table ingestion cost tracking |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata (1-year retention, 2-3h latency)
- `ORG_USAGE` = Organization-level (requires ORGADMIN, 2-24h latency)
- `INFO_SCHEMA` = Database-level (7-day retention, no latency)

---

## MVP Features Unlocked

1. **Idle Warehouse Cost Attribution Dashboard**
   - Use `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` vs `CREDITS_USED_COMPUTE`
   - Auto-detect auto-suspend misconfigurations
   - PR: SQL view + Streamlit card for top 10 idle-cost warehouses

2. **Service-Type Cost Explorer** 
   - Pivot `METERING_HISTORY` by `SERVICE_TYPE` (SPCS, Cortex, Serverless Tasks)
   - Group by `ENTITY_ID` for per-object costs (e.g., this specific SPCS service)
   - PR: Dynamic filter panel + time-series chart

3. **Anomaly Detection on Daily Credit Burn**
   - Use `METERING_DAILY_HISTORY` for "true" billed credits
   - Rolling 7d average + 2-sigma threshold
   - PR: Alert when daily credits exceed baseline + threshold

4. **Query-Level Cost Attribution**
   - Join `QUERY_HISTORY` (execution time) with `WAREHOUSE_METERING_HISTORY` (hourly credits)
   - Approximate cost per query = (query_time / warehouse_active_time) * hourly_credits
   - PR: Cost-per-query view for expensive query identification

5. **Organization-Level Account Spend Rollup**
   - Aggregate `ORGANIZATION_USAGE.ACCOUNTS` + cross-account warehouse metering
   - PR: Org admin cost breakdown by account + BU tags

---

## Concrete Artifacts

### Idle Warehouse Cost Query (from docs)
```sql
SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_cost,
  warehouse_name
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('days', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name;
```

### Service-Type Monthly Rollup
```sql
SELECT 
  DATE_TRUNC('month', start_time) AS month,
  service_type,
  SUM(credits_used) AS total_credits,
  COUNT(DISTINCT entity_id) AS object_count
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('days', -90, CURRENT_DATE())
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

### Cost Per Query (approximate)
```sql
WITH hourly_credits AS (
  SELECT 
    warehouse_id,
    DATE_TRUNC('hour', start_time) AS hour,
    SUM(credits_used_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('days', -7, CURRENT_DATE())
  GROUP BY 1, 2
),
query_time AS (
  SELECT 
    warehouse_id,
    DATE_TRUNC('hour', start_time) AS hour,
    SUM(execution_time) / 1000 / 3600 AS execution_hours -- convert ms to hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('days', -7, CURRENT_DATE())
    AND execution_time IS NOT NULL
  GROUP BY 1, 2
)
SELECT 
  hc.hour,
  hc.credits,
  qt.execution_hours,
  hc.credits / NULLIF(qt.execution_hours, 0) AS credits_per_execution_hour
FROM hourly_credits hc
LEFT JOIN query_time qt USING (warehouse_id, hour);
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORGANIZATION_USAGE views require ORGADMIN role | Org-wide features fail for non-org admins | Check `CURRENT_ROLE()` at runtime |
| Premium org views only available in org account | Cross-account query history unavailable | Graceful degrade to ACCOUNT_USAGE |
| CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes idle time | Idle cost calcs accurate but don't show _why_ idle | Correlated with QUERY_HISTORY timestamps |
| METERING_HISTORY latency up to 6 hours | Real-time alerts impossible; only periodic | Design for T+6h summaries, not real-time |
| Query-per-hour attribution is approximate | Per-query costs have error margin | Document approximation nature in UI |

---

## Links & Citations

1. **WAREHOUSE_METERING_HISTORY view** - https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
   *Idle cost calculation snippet from official docs verified*

2. **METERING_HISTORY view (Service Types)** - https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
   *25+ service types including SPCS, Cortex, Query Acceleration*

3. **Exploring Overall Cost (Snowsight)** - https://docs.snowflake.com/en/user-guide/cost-exploring-overall
   *Organization/Account Overview pages and Consumption drill-down*

4. **Organization Usage Schema** - https://docs.snowflake.com/en/sql-reference/organization-usage
   *Org-level views, premium features, latency documentation*

5. **Native App Framework Overview** - https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about
   *Structured logging via Event Tables for app telemetry*

6. **Account Usage Overview** - https://docs.snowflake.com/en/sql-reference/account-usage
   *Latency (2h typical), retention (1 year), dropped object inclusion*

---

## Next Steps / Follow-ups

- [ ] Verify `METERING_DAILY_HISTORY` schema and confirm credit adjustment formula
- [ ] Test `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` behavior with suspended warehouses
- [ ] Design org-account detection logic for premium view availability
- [ ] Draft ADR: Cost attribution methodology for queries vs tasks

---

*Generated by Snow • 2026-02-06 UTC*
