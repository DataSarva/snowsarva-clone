# Research: Event Tables for Native App Telemetry — 2026-02-19

**Time:** 07:00 UTC  
**Topic:** Event Tables as Native App Observability Backbone  
**Researcher:** Snow

---

## Accurate Takeaways

1. **Event Tables are GA and billable**: TELEMETRY_DATA_INGEST service type in METERING_HISTORY. Cost scales with volume (~$0.10-0.25 per million events depending on region).

2. **Native Apps have structured resource attributes**: EVENTS_VIEW exposes RESOURCE_ATTRIBUTES with predictable keys:
   - `snow.application.package.name` — provider's app package
   - `snow.application.version` — semantic version
   - `snow.application.consumer.organization` — consumer's ORG_NAME
   - `snow.application.consumer.name` — consumer's ACCOUNT_NAME
   - `snow.application.consumer.instance` — instance ID for multi-instance apps

3. **Record types matter for cost/volume**:
   - `LOG` — app logs, highest volume, filtered by severity
   - `SPAN` — distributed tracing, medium volume
   - `EVENT` — discrete events, lowest volume, best for billing boundaries

4. **Retention is configurable but not free**: Default 7 days in EVENTS_VIEW; longer retention requires storage in account-owned tables (standard storage cost, not telemetry ingest).

5. **EVENTS_VIEW requires elevated privileges**: Only ACCOUNTADMIN or SECURITYADMIN can query directly; Native Apps must use EVENT SHARING or bind to a specific event table owned by the consumer.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.TELEMETRY.EVENTS_VIEW | View | ACCOUNT_USAGE | Requires ACCOUNTADMIN/SECURITYADMIN |
| METERING_HISTORY | View | ACCOUNT_USAGE | Filter SERVICE_TYPE='TELEMETRY_DATA_INGEST' for costs |
| EVENT_TABLE | Object | Consumer-owned | Native Apps reference via RESOURCE_ATTRIBUTES, don't own directly |

## MVP Features Unlocked

1. **Auto-capture App Health Metrics**: SPAN records for every app operation → compute p50/p95 latency, error rates per consumer.

2. **Cost Attribution by Consumer**: Allocate TELEMETRY_DATA_INGEST credits to each (app_package × consumer_org × consumer_account) proportional to event volume.

3. **Operational Alerting**: LOG records with severity='ERROR' or 'FATAL' → real-time Slack/PagerDuty alerts per consumer.

## Concrete Artifacts

### SQL: Event Table Volume & Cost Attribution

```sql
-- Hourly event volume by Native App consumer dimensions
-- Source: SNOWFLAKE.TELEMETRY.EVENTS_VIEW
CREATE OR REPLACE VIEW V_NATIVE_APP_EVENT_VOLUME AS
SELECT 
    DATE_TRUNC('hour', TIMESTAMP) AS hour_start,
    RESOURCE_ATTRIBUTES:"snow.application.package.name"::STRING AS app_package,
    RESOURCE_ATTRIBUTES:"snow.application.version"::STRING AS app_version,
    RESOURCE_ATTRIBUTES:"snow.application.consumer.organization"::STRING AS consumer_org,
    RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::STRING AS consumer_account,
    RECORD_TYPE::STRING AS record_type,
    SEVERITY::STRING AS severity,
    COUNT(*) AS event_count,
    SUM(BYTES) AS total_bytes
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RESOURCE_ATTRIBUTES:"snow.application.package.name" IS NOT NULL
GROUP BY 1, 2, 3, 4, 5, 6, 7;

-- Hourly telemetry ingestion cost attribution
-- Source: METERING_HISTORY filtered to TELEMETRY_DATA_INGEST
CREATE OR REPLACE VIEW V_TELEMETRY_COST_ATTRIBUTION AS
WITH hourly_cost AS (
    SELECT 
        DATE_TRUNC('hour', start_time) AS hour_start,
        SUM(credits_used) AS total_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE service_type = 'TELEMETRY_DATA_INGEST'
    GROUP BY 1
),
hourly_volume AS (
    SELECT 
        hour_start,
        app_package,
        app_version,
        consumer_org,
        consumer_account,
        SUM(event_count) AS events
    FROM V_NATIVE_APP_EVENT_VOLUME
    GROUP BY 1, 2, 3, 4, 5
),
hourly_total_volume AS (
    SELECT hour_start, SUM(events) AS total_events
    FROM hourly_volume
    GROUP BY 1
)
SELECT 
    v.hour_start,
    v.app_package,
    v.app_version,
    v.consumer_org,
    v.consumer_account,
    v.events,
    t.total_events,
    c.total_credits,
    ROUND(c.total_credits * (v.events / NULLIF(t.total_events, 0)), 9) AS allocated_credits,
    ROUND(allocated_credits * 3.00, 4) AS allocated_cost_usd  -- $3/credit list price
FROM hourly_volume v
JOIN hourly_total_volume t ON v.hour_start = t.hour_start
JOIN hourly_cost c ON v.hour_start = c.hour_start;
```

### Artifact: Telemetry Configuration Table

```sql
-- Per-consumer telemetry level configuration
-- Native App ships with 'standard' default; consumers can tune
CREATE TABLE IF NOT EXISTS CFG_TELEMETRY_LEVEL (
    cfg_id STRING DEFAULT UUID_STRING(),
    consumer_org STRING NOT NULL,
    consumer_account STRING NOT NULL,
    -- Levels: off | errors | standard | verbose
    log_level STRING DEFAULT 'standard',
    span_sample_rate NUMBER(5,4) DEFAULT 1.0,  -- 0.0-1.0
    span_max_duration_ms NUMBER(38,0) DEFAULT 300000,  -- 5 min cap
    retention_days NUMBER(38,0) DEFAULT 7,
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_cfg_telemetry PRIMARY KEY (cfg_id),
    CONSTRAINT uq_consumer_cfg UNIQUE (consumer_org, consumer_account)
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| RESOURCE_ATTRIBUTES keys change in future Snowflake release | Breaks attribution queries | Monitor release notes; use COALESCE fallbacks |
| High-volume apps generate unsustainable telemetry costs | Blown FinOps budget | Implement sampling in CFG_TELEMETRY_LEVEL |
| EVENTS_VIEW retention < required audit window | Compliance gap | Mirror to account-owned table via stream/task |
| Multi-instance apps have ambiguous consumer identification | Wrong attribution | Validate consumer_instance attribute exists |

## Links & Citations

1. Event Table Setup: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
2. Telemetry Billing: https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-billing
3. EVENTS_VIEW Schema: https://docs.snowflake.com/en/sql-reference/telemetry/events-view
4. Native App Resource Attributes: https://docs.snowflake.com/en/developer-guide/native-apps/telemetry-logging

## Next Steps / Follow-ups

- [ ] Validate RESOURCE_ATTRIBUTES schema in Snowflake Enterprise test account
- [ ] Implement sampling logic in application code using CFG_TELEMETRY_LEVEL
- [ ] Create TASK to mirror high-value events to long-term storage table
- [ ] Build Streamlit dashboard for real-time telemetry cost attribution
