-- Telemetry v0 pipeline: build windowed facts from Event Tables
-- Date: 2026-02-01
-- Notes:
-- - Intended for Native App internal schema.
-- - Uses SNOWFLAKE.TELEMETRY.EVENTS_VIEW as the source (preferred).
-- - Produces 15-minute window facts into FACT_APP_OPERATION_WINDOW and FACT_APP_ERROR_WINDOW.

-- ----------------------------------------------------------------------------
-- 0) Source view (normalize JSON fields)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_EVENT_SPANS AS
SELECT
  TIMESTAMP::timestamp_ntz                      AS ts,
  START_TIMESTAMP::timestamp_ntz                AS start_ts,
  DATEDIFF('millisecond', START_TIMESTAMP, TIMESTAMP)::number(38,3) AS duration_ms,
  RESOURCE_ATTRIBUTES:"snow.application.package.name"::string       AS app_package,
  RESOURCE_ATTRIBUTES:"snow.application.version"::string            AS app_version,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.organization"::string AS consumer_org,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string      AS consumer_name,
  RECORD:"name"::string                         AS operation_name,
  RECORD                                       AS record,
  RECORD_ATTRIBUTES                            AS record_attributes
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'SPAN'
  AND START_TIMESTAMP IS NOT NULL;

CREATE OR REPLACE VIEW V_EVENT_LOGS AS
SELECT
  TIMESTAMP::timestamp_ntz AS ts,
  RESOURCE_ATTRIBUTES:"snow.application.package.name"::string AS app_package,
  RESOURCE_ATTRIBUTES:"snow.application.version"::string      AS app_version,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.organization"::string AS consumer_org,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string AS consumer_name,
  RECORD:"severity_text"::string AS severity,
  VALUE::string AS message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG';

-- ----------------------------------------------------------------------------
-- 1) Helper: compute 15m window start
-- ----------------------------------------------------------------------------
-- Window start = floor to 15-minute boundary.
CREATE OR REPLACE VIEW V_SPANS_15M AS
SELECT
  DATEADD(
    'minute',
    15 * FLOOR(DATE_PART('minute', ts) / 15),
    DATE_TRUNC('hour', ts)
  ) AS window_start,
  DATEADD('minute', 15, DATEADD('minute', 15 * FLOOR(DATE_PART('minute', ts) / 15), DATE_TRUNC('hour', ts))) AS window_end,
  app_package,
  app_version,
  operation_name,
  consumer_org,
  consumer_name,
  duration_ms
FROM V_EVENT_SPANS;

CREATE OR REPLACE VIEW V_LOGS_15M AS
SELECT
  DATEADD(
    'minute',
    15 * FLOOR(DATE_PART('minute', ts) / 15),
    DATE_TRUNC('hour', ts)
  ) AS window_start,
  DATEADD('minute', 15, DATEADD('minute', 15 * FLOOR(DATE_PART('minute', ts) / 15), DATE_TRUNC('hour', ts))) AS window_end,
  app_package,
  app_version,
  consumer_org,
  consumer_name,
  severity,
  message,
  SHA1(LOWER(REGEXP_REPLACE(message, '\\d+', '<n>'))) AS message_fingerprint
FROM V_EVENT_LOGS
WHERE severity IN ('WARN','ERROR','FATAL');

-- ----------------------------------------------------------------------------
-- 2) Upsert window facts (idempotent MERGE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_REFRESH_TELEMETRY_FACTS_15M(lookback_hours NUMBER)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Operation performance facts
  MERGE INTO FACT_APP_OPERATION_WINDOW t
  USING (
    SELECT
      window_start,
      window_end,
      app_package,
      app_version,
      operation_name,
      consumer_org,
      consumer_name,
      COUNT(*) AS spans,
      -- v0: errors derived from logs; set 0 here (can join later)
      0 AS errors,
      APPROX_PERCENTILE(duration_ms, 0.50) AS p50_ms,
      APPROX_PERCENTILE(duration_ms, 0.95) AS p95_ms,
      MAX(duration_ms) AS max_ms
    FROM V_SPANS_15M
    WHERE window_start >= DATEADD('hour', -lookback_hours, CURRENT_TIMESTAMP())
    GROUP BY 1,2,3,4,5,6,7
  ) s
  ON t.window_start = s.window_start
     AND t.app_package = s.app_package
     AND COALESCE(t.app_version,'') = COALESCE(s.app_version,'')
     AND t.operation_name = s.operation_name
     AND COALESCE(t.consumer_org,'') = COALESCE(s.consumer_org,'')
     AND COALESCE(t.consumer_name,'') = COALESCE(s.consumer_name,'')
  WHEN MATCHED THEN UPDATE SET
    window_end = s.window_end,
    spans = s.spans,
    errors = s.errors,
    p50_ms = s.p50_ms,
    p95_ms = s.p95_ms,
    max_ms = s.max_ms,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    window_start, window_end, app_package, app_version, operation_name,
    consumer_org, consumer_name, spans, errors, p50_ms, p95_ms, max_ms
  ) VALUES (
    s.window_start, s.window_end, s.app_package, s.app_version, s.operation_name,
    s.consumer_org, s.consumer_name, s.spans, s.errors, s.p50_ms, s.p95_ms, s.max_ms
  );

  -- Error facts
  MERGE INTO FACT_APP_ERROR_WINDOW t
  USING (
    SELECT
      window_start,
      window_end,
      app_package,
      app_version,
      consumer_org,
      consumer_name,
      severity,
      message_fingerprint,
      ANY_VALUE(message) AS message_sample,
      COUNT(*) AS occurrences
    FROM V_LOGS_15M
    WHERE window_start >= DATEADD('hour', -lookback_hours, CURRENT_TIMESTAMP())
    GROUP BY 1,2,3,4,5,6,7,8
  ) s
  ON t.window_start = s.window_start
     AND t.app_package = s.app_package
     AND COALESCE(t.app_version,'') = COALESCE(s.app_version,'')
     AND COALESCE(t.consumer_org,'') = COALESCE(s.consumer_org,'')
     AND COALESCE(t.consumer_name,'') = COALESCE(s.consumer_name,'')
     AND t.severity = s.severity
     AND t.message_fingerprint = s.message_fingerprint
  WHEN MATCHED THEN UPDATE SET
    window_end = s.window_end,
    message_sample = s.message_sample,
    occurrences = s.occurrences,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    window_start, window_end, app_package, app_version, consumer_org, consumer_name,
    severity, message_fingerprint, message_sample, occurrences
  ) VALUES (
    s.window_start, s.window_end, s.app_package, s.app_version, s.consumer_org, s.consumer_name,
    s.severity, s.message_fingerprint, s.message_sample, s.occurrences
  );

  RETURN 'ok';
END;
$$;

-- ----------------------------------------------------------------------------
-- 3) Task (runs every 15 minutes)
-- ----------------------------------------------------------------------------
-- NOTE: warehouse name and schedule should be parameterized per install.
CREATE OR REPLACE TASK TASK_REFRESH_TELEMETRY_FACTS_15M
  WAREHOUSE = '<SET_WAREHOUSE>'
  SCHEDULE = '15 MINUTE'
AS
  CALL SP_REFRESH_TELEMETRY_FACTS_15M(lookback_hours => 6);

-- End.
