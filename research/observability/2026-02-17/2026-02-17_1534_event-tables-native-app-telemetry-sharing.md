# Observability Research Note — Event Tables + Event Sharing for Native App Telemetry

- **When (UTC):** 2026-02-17 15:34
- **Scope:** Event Tables for telemetry collection, Event Sharing for provider-consumer usage attribution

## Accurate takeaways

1. **Event Tables are GA and required for Native App telemetry.** Consumer accounts must have an active event table before installing an app, or all app-generated telemetry (logs, traces, metrics) is discarded[1].

2. **Event Sharing enables the provider to debug apps running in consumer accounts.** When enabled, a masked/redacted copy of consumer telemetry is inserted into the provider's event table, restricted by event definitions (granular filters)[1].

3. **Event definitions act as filters on what gets shared.** Providers define these at publish time. Definitions include SNOWFLAKE$ALL, SNOWFLAKE$ERRORS_AND_WARNINGS, SNOWFLAKE$METRICS, SNOWFLAKE$TRACES, SNOWFLAKE$USAGE_LOGS, SNOWFLAKE$DEBUG_LOGS[1].

4. **Event Sharing is same-region only.** Shared events go to a designated provider account within the same region as the consumer; cross-region sharing is not supported[1].

5. **Cost responsibility is split.** Snowflake does not charge to enable event sharing, but consumers pay for ingestion/storage of events in their event table, and providers pay for storage of received shared events[1].

6. **Once enabled, event sharing cannot be revoked.** After consumer enables sharing (especially required event definitions), historical events cannot be unshared[1].

7. **Logs vs Traces have different data models.** Logs are independent strings; Traces are structured with spans and attributes (up to 128 span events limit); trace data is easier to query due to structured columns[2].

8. **Consumers cannot change log/trace levels.** Providers set these at publish time. Consumers can only influence sharing via event definitions[1][3].

9. **Dynamic Table refresh events can trigger alerts.** Event tables support alerting via CREATE ALERT on new data (e.g., refresh failures)[4].

10. **UDFs can emit excessive telemetry.** 10M rows passed to a UDF = 10M log entries. Use WARN level in production, DEBUG only during troubleshooting[3].

11. **Native Apps use standard logging APIs.** Python's `logging` module routes automatically to event table when active[2][5].

## Data sources / Snowflake objects

| Object | Schema | Notes |
|--------|--------|-------|
| `SNOWFLAKE.TELEMETRY.EVENTS` | TELEMETRY (SNOWFLAKE db) | Default event table if none set |
| `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` | TELEMETRY (SNOWFLAKE db) | Predefined view with RAP support |
| Application Event Table | Consumer-defined | Created via `CREATE EVENT TABLE` |
| `SHOW TELEMETRY EVENT DEFINITIONS IN APPLICATION <name>` | Information Schema | Lists event definitions for app[1] |
| `DESC APPLICATION <name>` | Information Schema | Shows log_level, trace_level, metric_level, effective_log_level[1] |
| Event Table Alerts | ACCOUNT/DB level | Can CREATE ALERT on event table insertions[4] |

## MVP features unlocked (PR-sized)

1) **Consumer Event Table Setup Wizard**: SQL template + UI guidance for consumers to create event table and enable telemetry collection for the FinOps Native App. Include cost estimate based on expected log volume.

2) **Event Sharing Consent Flow**: Pre-install checklist showing consumers what event definitions will be shared (filtered), with explicit opt-in and cost disclosure.

3) **Provider-side Telemetry Dashboard**: Views/queries on provider event table showing aggregated consumer usage patterns (anonymized where appropriate) for product improvement and support.

## Risks / assumptions

- **Assumption:** Consumers will accept the cost of event table storage + ingestion for telemetry. May need tiered event definitions (minimal vs full diagnostics).
- **Risk:** Event table storage costs could surprise consumers if app emits verbose logging. Need clear cost estimates in onboarding.
- **Risk:** Same-region limitation means global deployment requires regional provider accounts if telemetry sharing is critical.
- **Assumption:** Native App can emit structured custom spans via Snowpark telemetry APIs for business-level events (feature usage, cost operations).
- **Risk:** Cannot revoke sharing means privacy/compliance teams may resist enabling. Need granular event definitions and clear data classification.

## Concrete artifact: SQL for Event Table Pattern

### Consumer setup (run in consumer account before installation):
```sql
-- Create event table for telemetry collection
CREATE EVENT TABLE finops_telemetry_db.telemetry.consumer_event_table;

-- Set as active event table for account
ALTER ACCOUNT SET EVENT_TABLE = finops_telemetry_db.telemetry.consumer_event_table;

-- Grant appropriate access
GRANT USAGE ON DATABASE finops_telemetry_db TO ROLE your_role;
GRANT USAGE ON SCHEMA telemetry TO ROLE your_role;
GRANT SELECT, INSERT ON EVENT TABLE finops_telemetry_db.telemetry.consumer_event_table TO ROLE your_role;
```

### Provider post-install enable sharing:
```sql
-- View available event definitions for the app
SHOW TELEMETRY EVENT DEFINITIONS IN APPLICATION my_finops_app;

-- Enable event sharing (required definitions auto-enabled, optional ones explicit)
ALTER APPLICATION my_finops_app SET AUTHORIZE_TELEMETRY_EVENT_SHARING = true;

-- Or selectively enable specific event types
ALTER APPLICATION my_finops_app SET SHARED TELEMETRY EVENTS ('SNOWFLAKE$USAGE_LOGS', 'SNOWFLAKE$ERRORS_AND_WARNINGS');
```

### Provider-side query (in provider event table):
```sql
-- Query shared events from consumers
SELECT 
  TIMESTAMP,
  RESOURCE_ATTRIBUTES['snow.database.name']::STRING AS consumer_db,
  RESOURCE_ATTRIBUTES['snow.application.name']::STRING AS app_name,
  RECORD['severity_text']::STRING AS severity,
  VALUE AS message,
  RECORD_ATTRIBUTES['snow.application.shared']::BOOLEAN AS is_shared
FROM provider_event_table
WHERE RESOURCE_ATTRIBUTES['snow.application.name'] = 'MY_FINOPS_APP'
  AND RECORD_ATTRIBUTES['snow.application.shared'] = true
ORDER BY TIMESTAMP DESC
LIMIT 100;
```

### Alert on telemetry event:
```sql
-- Alert on error-level events from app
CREATE ALERT finops_app_errors
  WAREHOUSE = alert_wh
  SCHEDULE = '1 MINUTE'
  IF (EXISTS (
    SELECT 1 FROM consumer_event_table
    WHERE RESOURCE_ATTRIBUTES['snow.application.name'] = 'MY_FINOPS_APP'
      AND RECORD['severity_text'] = 'ERROR'
      AND TIMESTAMP > SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
  ))
  THEN CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
    SNOWFLAKE.NOTIFICATION.TEXT_PLAIN('FinOps App error detected'),
    '{"email_integration": {}}'
  );
```

## Links / references

[1] https://docs.snowflake.com/en/developer-guide/native-apps/ui-consumer-enable-logging — Event tracing and sharing for Native Apps (GA)

[2] https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up — Event table overview, OpenTelemetry model

[3] https://docs.snowflake.com/en/developer-guide/builders/observability — Observability best practices, telemetry optimization for UDFs

[4] https://docs.snowflake.com/en/user-guide/dynamic-tables-monitor-event-table-alerts — Event table monitoring and alerts

[5] https://www.snowflake.com/en/blog/collect-logs-traces-snowflake-apps/ — Blog: Collect Logs and Traces From Your Snowflake Applications

[6] https://docs.snowflake.com/en/sql-reference/sql/create-event-table — CREATE EVENT TABLE reference

---
**Research completed via Parallel Search/Extract API**
