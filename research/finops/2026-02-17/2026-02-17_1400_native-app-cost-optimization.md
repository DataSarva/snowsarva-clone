# Research: FinOps - 2026-02-17

**Time:** 14:00 UTC  
**Topic:** Snowflake Native App Framework + FinOps Cost Optimization Integration  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. The Snowflake Native App Framework enables providers to share data applications with business logic (stored procedures, functions, Streamlit apps) to consumers via the Snowflake Marketplace or private listings.

2. Native Apps support versioning and patching, allowing incremental releases to consumers without full redeployment.

3. ACCOUNT_USAGE and ORGANIZATION_USAGE schemas provide programmatic access to cost data with up to 72-hour latency.

4. Snowpark Container Services (SPCS) extends Native App capabilities by allowing containerized workloads with custom runtimes; billed separately from virtual warehouse compute.

5. Structured logging via Event Tables is available for Native Apps, enabling observability into application performance and user interactions.

6. Cost exploration is available through Snowsight Admin → Cost Management, requiring ORGADMIN or account-level admin roles with appropriate access grants.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Core for compute cost attribution |
| ACCOUNT_USAGE.STORAGE_USAGE_HISTORY | View | ACCOUNT_USAGE | Storage costs over time |
| ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | View | ORG_USAGE | Cross-account billing aggregation |
| INFORMATION_SCHEMA.WAREHOUSE_SIZE | View | INFO_SCHEMA | Warehouse resource mapping |
| EVENT_TABLE | Object | Account-level | Logs/metrics for Native App observability |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App Cost Dashboard Widget**: Embed a Streamlit component inside the FinOps Native App that queries ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY to show account-level spend trends with filtering by date range.

2. **SPCS Cost Attribution Module**: Add a view that joins Snowpark Container Services compute costs (from ACCOUNT_USAGE) to specific Native App deployments using EVENT_TABLE metadata tags.

3. **Cost Anomaly Detector**: A scheduled task using Snowpark Python that queries WAREHOUSE_METERING_HISTORY daily, calculates z-scores for spend patterns, and notifies via email/webhook when thresholds exceeded.

4. **Consumer Usage Telemetry**: Capture Native App feature usage via EVENT_TABLE structured logging, enabling provider-side analytics on which features drive compute costs.

5. **Chargeback Report Generator**: SQL template that generates monthly cost breakdowns per department/user using ACCOUNT_USAGE views, exportable to CSV from Streamlit UI.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Event Table Logging Schema for Native Apps

```sql
-- Create event table for Native App telemetry
CREATE EVENT TABLE IF NOT EXISTS finops_db.telemetry.app_events;

-- Enable logging for the Native App
ALTER APPLICATION my_finops_app SET LOG_LEVEL = 'INFO';

-- Sample logging call from within app
-- SYSTEM$LOG('INFO', '{"event": "feature_used", 
--   "feature": "cost_anomaly_scan", 
--   "user": CURRENT_USER(), 
--   "timestamp": CURRENT_TIMESTAMP()}');
```

### Daily Cost Anomaly Detection SQL

```sql
WITH daily_spend AS (
  SELECT 
    DATE(start_time) as spend_date,
    warehouse_name,
    SUM(credits_used) as daily_credits,
    AVG(SUM(credits_used)) OVER (
      PARTITION BY warehouse_name 
      ORDER BY DATE(start_time) 
      ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) as avg_credits_30d,
    STDDEV(SUM(credits_used)) OVER (
      PARTITION BY warehouse_name 
      ORDER BY DATE(start_time) 
      ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) as std_credits_30d
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -35, CURRENT_DATE())
  GROUP BY DATE(start_time), warehouse_name
)
SELECT 
  spend_date,
  warehouse_name,
  daily_credits,
  CASE 
    WHEN ABS(daily_credits - avg_credits_30d) > 2 * std_credits_30d 
    THEN 'ANOMALY_DETECTED' 
    ELSE 'NORMAL' 
  END as status
FROM daily_spend
WHERE spend_date >= CURRENT_DATE() - 1
ORDER BY daily_credits DESC;
```

### SPCS Cost View Mapping

```sql
-- View to attribute SPCS compute to Native Apps
CREATE OR REPLACE VIEW finops_db.views.spcs_spend_by_app AS
SELECT 
  s.service_name,
  s.database_name,
  s.schema_name,
  s.credits_used,
  s.start_time,
  a.application_name,
  a.application_version
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY s
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.APPLICATON_ROLES a
  ON s.role_name = a.application_role_name
WHERE s.service_type = 'SPCS';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| 72-hour latency in ACCOUNT_USAGE is acceptable for daily anomaly detection | Medium | Test with synthetic data; consider streaming alternative if needed |
| SPCS billing is available in same views as warehouse compute | High | Verify view schema in actual Snowflake account; document differences |
| Event Tables have retention limits that may affect long-term telemetry | Low | Check default retention policy; plan archival strategy |
| Consumer accounts may not have ORG_USAGE access for cross-account insights | Medium | Design fallback to local ACCOUNT_USAGE only |

## Links & Citations

1. [Snowflake Native App Framework Overview](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about) - Core architecture, provider/consumer model, versioning capabilities

2. [Snowpark Container Services Documentation](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview) - SPCS use cases, integration patterns, GPU/CPU workloads

3. [Exploring Overall Cost in Snowflake](https://docs.snowflake.com/en/user-guide/admin-monitoring-usage) - ACCOUNT_USAGE/ORG_USAGE schemas, Snowsight cost management UI

## Next Steps / Follow-ups

- [ ] Verify SPCS billing view schema in test Snowflake account (can vary by region)
- [ ] Prototype Event Table logging for Native App features
- [ ] Build PR for Cost Anomaly Detector scheduled task
- [ ] Document consumer vs provider cost visibility limitations
- [ ] Research Streamlit component options for embedded cost charts

---

**Status:** ✅ Complete  
**Research Time:** ~5 min  
**Citations:** 3 authoritative Snowflake docs
