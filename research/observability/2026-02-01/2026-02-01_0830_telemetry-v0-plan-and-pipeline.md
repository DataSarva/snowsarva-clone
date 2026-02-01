# Observability Research Note — Telemetry v0 plan + pipeline (15m window facts)

- **When (UTC):** 2026-02-01 08:30
- **Scope:** telemetry, Event Tables, query perf

## Accurate takeaways
- Snowflake Event Tables can be treated as the raw telemetry stream; downstream signals should be windowed/aggregated to reduce cost and improve UX.
- Provider event sharing is optional and environment-dependent; v0 should be valuable in consumer-only mode.

## Telemetry schema ideas
- Two curated fact tables unlock most UI and detection needs:
  - `FACT_APP_OPERATION_WINDOW` (span latency by operation)
  - `FACT_APP_ERROR_WINDOW` (error counts by message fingerprint)

## MVP features unlocked (PR-sized)
1) A deterministic **15-minute refresh pipeline** using a stored procedure + task.
2) A minimal **"Telemetry Health"** check that asserts `EVENTS_VIEW` is readable + tells admins how to enable/associate an event table.

## Risks / assumptions
- Some JSON fields (e.g., app version attribute names) may differ depending on instrumentation; treat as best-effort and document alternatives.
- Windowing logic assumes event timestamps are in sync and span start/end are present.

## Links / references
- Event table setup: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
- Event table columns: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-columns
