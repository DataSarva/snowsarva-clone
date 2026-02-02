# Observability Research Note — Event Tables as FinOps Telemetry (cost + attribution)

- **When (UTC):** 2026-02-02 07:00
- **Scope:** telemetry, Event Tables, query perf

## Accurate takeaways
- Snowflake provides a default **event table** `SNOWFLAKE.TELEMETRY.EVENTS` and a safer companion view `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` for querying event data. You can also create a custom event table and associate it to an account or database via the `EVENT_TABLE` parameter. (This controls the scope of which objects’ telemetry is captured.)
- **Telemetry ingestion costs money**: Snowflake batches and ingests logged messages into the event table using **Snowflake-managed (serverless) resources** and bills these costs as separate line items. Snowflake explicitly calls out the **METERING_HISTORY / METERING_DAILY_HISTORY** views for tracking this over time.
- The account usage metering views include `SERVICE_TYPE = 'TELEMETRY_DATA_INGEST'`, which is the billable category tied to event table telemetry ingestion.
- Event tables have a **fixed schema** aligned to OpenTelemetry concepts. Key columns for analytics are:
  - `TIMESTAMP`, `START_TIMESTAMP` (span duration derivable)
  - `RECORD_TYPE` (LOG, SPAN, SPAN_EVENT, METRIC, EVENT)
  - `RESOURCE_ATTRIBUTES` / `RECORD` / `RECORD_ATTRIBUTES` (JSON payloads where Snowflake/clients write dimensions)

## Telemetry schema ideas
### 1) Treat telemetry itself as a first-class FinOps cost center
If the FinOps Native App emits telemetry (logs/spans), we should track:
- **How much telemetry ingestion costs** (credits/day and credits/hour)
- Which **application packages/versions** and which **feature operations** are causing telemetry volume

Practical approach:
- Pull billable credits from `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` where `SERVICE_TYPE='TELEMETRY_DATA_INGEST'`.
- In the same hourly windows, compute event volume by app dimensions in `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` (typically via `RESOURCE_ATTRIBUTES` fields such as `snow.application.package.name` / `snow.application.version`).
- Allocate telemetry ingest credits proportionally by event volume (and optionally weight SPANs more than LOGs).

This gives us a **telemetry chargeback** mechanism, which is especially relevant for a Native App that might run across many consumer accounts.

### 2) Cost guardrails: “telemetry budget” and “telemetry SLO”
Given Snowflake’s note that **telemetry levels** control cost/volume, the app can enforce (or at least recommend):
- Default telemetry level: ERROR/WARN only for most consumers
- A “debug window” (time-bound higher level) for active troubleshooting
- A “telemetry budget” configuration: alert when `TELEMETRY_DATA_INGEST` credits exceed thresholds

### 3) Data model: keep hourly facts to enable tight attribution
Hourly metering (`METERING_HISTORY`) is the right grain for attribution because telemetry volume can be bursty.

Proposed new tables/views drafted under `sql/telemetry_ingest_cost_attribution_draft.sql`:
- `FACT_TELEMETRY_INGEST_HOUR`
- `FACT_TELEMETRY_INGEST_APP_HOUR`

## MVP features unlocked (PR-sized)
1) **Telemetry cost dashboard (daily + hourly):** show `TELEMETRY_DATA_INGEST` credits and trendline; link to the docs page about telemetry billing.
2) **Telemetry cost attribution (per app_package/app_version):** allocate hourly ingest credits proportionally to event volume by app dimensions.
3) **“Turn it down” recommendation:** if telemetry costs spike, recommend lowering telemetry level and/or enabling sampling.

## Risks / assumptions
- The exact `RESOURCE_ATTRIBUTES` keys present in `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` depend on runtime / instrumentation. The example keys used in our existing `telemetry_v0_pipeline.sql` are assumed to be present for Native Apps; we should validate in a real account.
- `METERING_HISTORY.NAME/ENTITY_ID` semantics for `TELEMETRY_DATA_INGEST` may not identify the event table or the emitting object. The proposed attribution uses **volume correlation**, not direct billing IDs.
- Latency: `ACCOUNT_USAGE.METERING_HISTORY` can lag by up to ~180 minutes (and some columns can lag longer), so dashboards/alerts must tolerate delay.

## Links / references
- Snowflake Docs — **Event table overview**: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
- Snowflake Docs — **Event table columns**: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-columns
- Snowflake Docs — **CREATE EVENT TABLE**: https://docs.snowflake.com/en/sql-reference/sql/create-event-table
- Snowflake Docs — **Costs of telemetry data collection**: https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-billing
- Snowflake Docs — **METERING_HISTORY (ACCOUNT_USAGE)** (includes `TELEMETRY_DATA_INGEST`): https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
- Snowflake Docs — **METERING_DAILY_HISTORY (ACCOUNT_USAGE)**: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
- Snowflake Docs — **Understanding compute cost (serverless credit usage)**: https://docs.snowflake.com/en/user-guide/cost-understanding-compute
