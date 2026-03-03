# Research: Event Tables for FinOps Native App Telemetry

**Time (UTC):** 2026-03-03 07:00  
**Topic:** Snowflake Event Tables (OpenTelemetry-based) for Native App Observability & FinOps Cost Attribution  
**Researcher:** Snow (AI Assistant)  

---

## Accurate Takeaways

1. **Snowflake Event Tables are OpenTelemetry-native.** They collect logs, spans (traces), and metrics using the OpenTelemetry data model. This enables interoperability with external tools (Datadog, Grafana) without data transformation overhead.

2. **Event Tables vs ACCOUNT_USAGE/ORG_USAGE serve distinct use cases:**
   - **ACCOUNT_USAGE**: Historical billing and query audit data (retention ~365 days, latency ~hours)
   - **ORG_USAGE**: Organization-level metering "truth" with currency (retention ~397 days, latency ~72h)
   - **Event Tables**: Real-time application telemetry (UDFs/SPs/Streamlit), custom spans, metrics, logs (no fixed retention, configurable)

3. **Event Tables are NOT automatically available for FinOps attribution.** Native apps using Event Tables must explicitly emit cost-attributable telemetry. There is no default "cost" dimension in Event Table schema—it's application-defined.

4. **Snowflake Native Apps Framework has explicit health monitoring.** Provider apps can report health status via `SYSTEM$REPORT_HEALTH_STATUS()` and consumers query `ACCOUNT_USAGE.APPLICATION_STATE` for `LAST_HEALTH_STATUS`.

5. **Row-level telemetry costs can explode.** UDFs emit per-row spans if instrumented—10M rows → 10M event rows. Best practice: use conditional logging (WARN in production) and try/catch isolation.

6. **Event Tables support custom attributes** (key-value pairs attachable to spans). These are queryable with standard SQL—making them suitable for tagging queries with `team`, `environment`, `cost_center` for downstream FinOps.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.EVENT_TABLE` | View | ACCOUNT_USAGE | All event tables in account (schema: `LOGS`, `SPANS`, `METRICS`)
| `EVENT_TABLE.LOGS` | Table | Application-defined | Timestamp, severity, message, trace_id
| `EVENT_TABLE.SPANS` | Table | Application-defined | Span start/end, duration_ms, operation, parent_span_id, attributes
| `EVENT_TABLE.METRICS` | Table | Auto/Snowflake | CPU, memory usage for UDF execution
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Links query_id to telemetry spans via `QUERY_ID` attribute
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Historical credits per warehouse for attribution
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | ORG_USAGE | Ground-truth billing credits (requires ORGADMIN)
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_STATE` | View | ACCOUNT_USAGE | Native App health status, consumer info, last_updated
| `SYSTEM$REPORT_HEALTH_STATUS()` | UDF | Native App Framework | Called by provider app to report OK/FAILED/PAUSED

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level (requires elevated role)
- `INFO_SCHEMA` = Database-level metadata

## MVP Features Unlocked

1. **Native App Cost Attribution Pipeline**  
   - Span-level custom attributes for `team_id`, `cost_center`, `project_code`  
   - Periodic task aggregates spans → cost attribution by tag  
   - Link spans to `QUERY_HISTORY` for warehouse credit mapping

2. **FinOps Observability Dashboard (Streamlit in Snowflake)**  
   - Visualize span duration vs warehouse costs  
   - Alert thresholds on "expensive slow queries" by team attribution

3. **Cost-Aware Telemetry Sampling**  
   - Conditional span emission controlled by resource monitor state  
   - Downsample high-volume UDFs to manage event table growth

## Concrete Artifacts

### SQL Schema: Event Table Ingestion for FinOps Native App

See: `/home/ubuntu/.openclaw/workspace/sql/telemetry_event_tables_ingest_schema.sql`

Key design:
- Unified schema for `SPANS`, `LOGS`, `METRICS`  
- Custom attribute extraction (`team_id`, `cost_center`)  
- Join bridge to `QUERY_HISTORY` and `WAREHOUSE_METERING_HISTORY`  
- Retention policy (365 days) + partition strategy

### Pseudocode: Cost-Aware Span Emit

```python
# In Snowpark Python handler
import snowflake.telemetry as otel
from snowflake.snowpark.context import get_active_session

def compute_expensive_operation(team_id: str, cost_center: str):
    tracer = otel.get_tracer(__name__)
    with tracer.start_as_current_span("compute_operation") as span:
        span.set_attribute("team_id", team_id)
        span.set_attribute("cost_center", cost_center)
        span.set_attribute("app_name", "finops_native_app")
        
        # ... actual work ...
        result = heavy_computation()
        span.set_attribute("rows_processed", result.row_count)
        return result
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Event Table latencies not documented for real-time attribution | Lag between span emission and queryable data unknown | Requires POC measurement in test account |
| Custom attributes key collision | Teams use inconsistent naming conventions (team_id vs team) | Schema enforcement via wrapper functions |
| Span volume explosion for high-volume UDFs | Event table storage costs, query performance | Implement sampling logic in handler |
| ORG_USAGE unavailable in consumer account | Cannot reconcile event data with billed truth | Feature flag heuristics with ACCOUNT_USAGE fallback |
| Native App provider cannot read consumer Event Tables | Native App telemetry isolation prevents cross-attribution | Requires consumer-side telemetry task export |

## Links & Citations

1. Snowflake Docs: [Logging, tracing, and metrics](https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-overview)  
2. Snowflake Docs: [Observability in Snowflake apps](https://docs.snowflake.com/en/developer-guide/builders/observability)  
3. Snowflake Docs: [Use monitoring for an app](https://docs.snowflake.com/en/developer-guide/native-apps/monitoring)  
4. OpenTelemetry: [OpenTelemetry Specification](https://opentelemetry.io/docs/)  
5. Related prior research: `extract_telemetry_native_1772331027.json` (workspace)

## Next Steps / Follow-ups

- [ ] Validate span attribute query performance on Event Table with >100M rows
- [ ] Design wrapper UDF for consistent cost_center/team_id tagging
- [ ] POC: Link span `duration_ms` to `WAREHOUSE_METERING_HISTORY` credits for cost attribution
- [ ] Evaluate `ALTER EVENT TABLE SET RETENTION_DAYS` for cost optimization
- [ ] Create Streamlit dashboard mock for span-based cost analysis
