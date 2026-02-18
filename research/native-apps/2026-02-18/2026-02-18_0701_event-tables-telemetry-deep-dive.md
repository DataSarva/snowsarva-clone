# Research: Native Apps — Event Tables Telemetry Deep Dive
**Time:** 07:01 UTC  
**Topic:** Snowflake Event Tables for Native App Telemetry & Observability  
**Researcher:** Snow  

---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **Event Tables are the canonical telemetry sink for Snowflake.** Native Apps (both provider and consumer) can write telemetry via `SYSTEM$LOG_EVENT` or automatically via Event Table configuration. The telemetry flows to `SNOWFLAKE.TELEMETRY.EVENTS_VIEW`.

2. **Two record types matter for observability:** `RECORD_TYPE='SPAN'` (distributed tracing/timing) and `RECORD_TYPE='LOG'` (structured logging). Spans contain timing metrics (duration_ms); logs contain severity and messages.

3. **Cost of telemetry is real.** `TELEMETRY_DATA_INGEST` appears in `METERING_HISTORY` as a distinct service type. Unbounded verbose logging can materially impact costs.

4. **Native Apps emit identifying resource attributes.** The `RESOURCE_ATTRIBUTES` variant column contains keys like `snow.application.package.name`, `snow.application.version`, `snow.application.consumer.organization`, `snow.application.consumer.name`. This enables per-app, per-consumer observability.

5. **Sampling and retention are configurable.** Applications can set sampling rates (0.0 - 1.0) and retention policies to manage ingest volume. Default behavior retains data based on instance policy.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` | View | Account-level | Canonical event table output. Contains TIMESTAMP, RECORD_TYPE, SEVERITY, MESSAGE, RESOURCE_ATTRIBUTES, etc. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Contains `TELEMETRY_DATA_INGEST` service_type for cost tracking. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Can correlate with event volume to estimate per-warehouse telemetry overhead. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked
*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution View for Telemetry Ingest:** Aggregate `METERING_HISTORY.TELEMETRY_DATA_INGEST` credits and allocate proportionally to (app_package, consumer) based on event volume counts. This enables chargeback of telemetry costs to the responsible Native App components.

2. **App Performance Dashboard (Spans):** Materialize hourly rollups from `EVENTS_VIEW` where `RECORD_TYPE='SPAN'` grouped by (app_package, operation_name). Compute p50/p95 latency, error rates, throughput. This is the "application performance" view for Native App providers.

3. **Alerting on Error Volume Surge:** Create a task + alert that counts `RECORD_TYPE='LOG'` AND `SEVERITY IN ('ERROR','FATAL')` per (app_package, consumer_name) hourly. Alert when error count exceeds 3-sigma historical baseline.

---

## Concrete Artifacts
*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Event Tables Ingestion Cost Attribution View

See detailed implementation: `sql/telemetry_event_tables_cost_attribution_v1.sql`

Core concept: Join `EVENTS_VIEW` event counts with `METERING_HISTORY` telemetry credits to allocate cost proportionally:

```sql
-- Simplified allocation logic (see SQL file for full MERGE procedure)
WITH ingest AS (
  SELECT DATE_TRUNC('hour', start_time) AS hour_start,
         SUM(credits_used) AS credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE service_type = 'TELEMETRY_DATA_INGEST'
  GROUP BY 1
),
vol AS (
  SELECT DATE_TRUNC('hour', TIMESTAMP) AS hour_start,
         RESOURCE_ATTRIBUTES:"snow.application.package.name"::string AS app_package,
         COUNT(*) AS events
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  GROUP BY 1,2
)
-- Allocate proportionally: app_credits = total_credits * (app_events / total_events)
SELECT v.hour_start, v.app_package, v.events,
       i.credits_used * (v.events / t.events_total) AS allocated_credits
FROM vol v
JOIN (SELECT hour_start, SUM(events) AS events_total FROM vol GROUP BY 1) t
  ON v.hour_start = t.hour_start
JOIN ingest i ON v.hour_start = i.hour_start;
```

### Artifact: Span Performance Aggregation View

```sql
-- Hourly performance rollup for Native App operations
CREATE OR REPLACE VIEW V_APP_OPERATION_LATENCY_HOURLY AS
SELECT DATE_TRUNC('hour', TIMESTAMP) AS hour_start,
       RESOURCE_ATTRIBUTES:"snow.application.package.name"::string AS app_package,
       RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string AS consumer_name,
       NAME AS operation_name,
       COUNT(*) AS span_count,
       AVG(DURATION) AS avg_duration_ms,
       APPROX_PERCENTILE(DURATION, 0.50) AS p50_ms,
       APPROX_PERCENTILE(DURATION, 0.95) AS p95_ms,
       MAX(DURATION) AS max_ms
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'SPAN'
  AND TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4;
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact resource attribute keys (e.g., `snow.application.consumer.name`) may vary across Snowflake versions. | High | Test against actual provider/consumer accounts in multiple regions. |
| EVENTS_VIEW has latency (~3 hours). Real-time alerting may need complementary streams. | Medium | Document latency assumption in consumer docs. |
| DURATION column units may change (currently milliseconds). | Medium | Add unit detection guardrails in SQL. |
| TELEMETRY_DATA_INGEST may bundle non-Event-Table costs (e.g., logs in external stages). | Low | Add comments in cost attribution logic; monitor for drift. |

---

## Links & Citations

1. Snowflake Docs: Event Table overview — https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
2. Snowflake Docs: Telemetry billing — https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-billing
3. `METERING_HISTORY` — https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Existing draft: `sql/telemetry_ingest_cost_attribution_draft.sql` (v0 telemetry ingest schema)

---

## Next Steps / Follow-ups

- [ ] Validate resource attribute keys match actual EVENTS_VIEW output in dev account
- [ ] Create stored procedure for incremental MERGE of telemetry cost attribution
- [ ] Build Streamlit/Native App UI view for "my app's telemetry cost" (consumer-facing)
- [ ] Design retention policy configuration table (CFG_TELEMETRY from existing schema)

---
*End research note.*
