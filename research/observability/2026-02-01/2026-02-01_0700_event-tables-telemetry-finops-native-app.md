# Observability Research Note — Event Tables telemetry for FinOps Native App (provider + consumer)

- **When (UTC):** 2026-02-01 07:00
- **Scope:** Snowflake Event Tables + Native Apps event sharing; how to turn telemetry into FinOps signals (cost attribution + performance intelligence)

## Accurate takeaways
- Snowflake collects telemetry emitted by Snowflake objects (procedures/UDFs) into an **event table**; Snowflake includes a **default event table** `SNOWFLAKE.TELEMETRY.EVENTS` that is active unless you deactivate/disassociate it. You can also create a custom event table via `CREATE EVENT TABLE` and associate it to an account or database using `ALTER ACCOUNT/ALTER DATABASE ... SET EVENT_TABLE = ...`.
- Event tables have a **predefined OpenTelemetry-aligned schema** with key columns like `TIMESTAMP`, `START_TIMESTAMP`, `TRACE`, `RESOURCE_ATTRIBUTES`, `RECORD_TYPE`, `RECORD`, `RECORD_ATTRIBUTES`, and `VALUE` (message/value payload).
- Snowflake provides a default view `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` intended to expose event data more safely (and can be governed using row access policies). Snowflake also provides application roles `SNOWFLAKE.EVENTS_ADMIN` and `SNOWFLAKE.EVENTS_VIEWER` to manage access to the default event table / view.
- **Native Apps provider event sharing**: if the provider does not set up an **event account + active event table in the same region** *before* a consumer installs an app, the consumer’s shared logs/trace events are **discarded**.
- When events are shared from consumer → provider, Snowflake populates certain `RESOURCE_ATTRIBUTES` fields to help identify the source (e.g., `snow.application.package.name`, `snow.application.consumer.organization`, `snow.application.consumer.name`, `snow.listing.name`, `snow.listing.global_name`). Some sensitive attributes are **not shared**; `snow.database.name` and `snow.query.id` are shared only as SHA-1 hashes (`snow.database.hash`, `snow.query.hash`).

## Telemetry schema ideas (for FinOps + product analytics)
Goal: treat Event Tables as an *immutable raw telemetry stream*, and build a small curated “facts” layer for the app.

1) **Raw ingestion / parsing**
- Source: `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` (preferred) or the active event table.
- Filter patterns:
  - `RECORD_TYPE = 'LOG'` for structured/unstructured logs.
  - `RECORD_TYPE IN ('SPAN','SPAN_EVENT')` for trace timings (span duration via `TIMESTAMP - START_TIMESTAMP`).
- Suggested derived fields:
  - `app_pkg_name := RESOURCE_ATTRIBUTES:"snow.application.package.name"::string`
  - `consumer_org := RESOURCE_ATTRIBUTES:"snow.application.consumer.organization"::string`
  - `consumer_name := RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string`
  - `listing_global := RESOURCE_ATTRIBUTES:"snow.listing.global_name"::string`
  - `severity := RECORD:"severity_text"::string`
  - `message := VALUE::string`

2) **FinOps attribution join strategy (provider-side)**
Because consumer query ids may only be shared as hashes, favor a join strategy that does *not* require raw `QUERY_ID`.
- Use telemetry as the “what happened + when + which app + which consumer” stream.
- Join to costs via **time windows** and high-level dimensions (warehouse, role, database hash, etc.) where available.
- If the customer provides an opt-in “support bundle” mapping (their raw query_id → hash), provider can do deeper correlation.

3) **MVP “event→signal” transforms**
- **Error rate & top errors per app version**: group by `app_pkg_name`, `severity`, `message` (or a hashed normalized message), and 15m buckets.
- **Latency SLO per endpoint/procedure**: for `SPAN`, use `RECORD:"name"` as operation name; compute p50/p95 duration.
- **Cost guardrails** (consumer-side; or provider-side when possible): use spans to attribute “expensive operations” to app features.

## Example queries (copy/paste starter SQL)
### 1) Recent WARN/ERROR logs (provider-side)
```sql
SELECT
  TIMESTAMP,
  RESOURCE_ATTRIBUTES:"snow.application.package.name"::string AS app_package,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string AS consumer,
  RECORD:"severity_text"::string AS severity,
  VALUE::string AS message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
  AND RECORD:"severity_text"::string IN ('WARN','ERROR','FATAL')
  AND TIMESTAMP >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY TIMESTAMP DESC;
```

### 2) Span durations by operation (p95)
```sql
SELECT
  RESOURCE_ATTRIBUTES:"snow.application.package.name"::string AS app_package,
  RECORD:"name"::string AS operation,
  APPROX_PERCENTILE(DATEDIFF('millisecond', START_TIMESTAMP, TIMESTAMP), 0.95) AS p95_ms,
  COUNT(*) AS spans
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'SPAN'
  AND START_TIMESTAMP IS NOT NULL
  AND TIMESTAMP >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1,2
ORDER BY p95_ms DESC;
```

## MVP features unlocked (PR-sized)
1) **In-app “Telemetry Health” page**: checks whether an active event table exists (and in provider org: whether event sharing account + active event table are configured per region), with human-readable remediation steps.
2) **“Top expensive operations” report**: p95 span duration + error counts by operation name + app version; exportable as a table/view.
3) **Provider triage dashboard**: per-consumer error rate + newest fatal messages (from `EVENTS_VIEW`), gated behind provider-only role and RAP.

## Risks / assumptions
- Assumption: the Native App’s procedures/UDFs are instrumented sufficiently for spans/logs to be meaningful; otherwise, we only see Snowflake-generated telemetry.
- Provider-side correlation to consumer spend may be limited by the event sharing privacy model (e.g., query id hashing); design should treat deep correlation as opt-in.
- Telemetry collection **incurs cost**; we need explicit retention, sampling, and “levels” guidance in the product.

## Links / references
- Event table overview / setup: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
- Event table columns (OpenTelemetry-aligned schema): https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-columns
- CREATE EVENT TABLE SQL reference: https://docs.snowflake.com/en/sql-reference/sql/create-event-table
- Native Apps (provider): set up/manage event table + event sharing model: https://docs.snowflake.com/en/developer-guide/native-apps/event-manage-provider
