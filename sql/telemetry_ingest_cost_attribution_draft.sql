-- Telemetry ingest cost attribution (draft)
-- Date: 2026-02-02
-- Goal: treat Event Table telemetry ingestion as a FinOps-tracked serverless cost and allocate it to app dimensions.
-- Sources:
--  - SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY (SERVICE_TYPE='TELEMETRY_DATA_INGEST')
--  - SNOWFLAKE.TELEMETRY.EVENTS_VIEW (RECORD_TYPE, RESOURCE_ATTRIBUTES, etc.)
--
-- References:
--  - Event table overview: https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up
--  - Telemetry billing:   https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-billing
--  - Metering history:    https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

-- NOTE: This is a draft for the FinOps Native App internal schema. Adjust DB/SCHEMA qualifiers as needed.

-- ----------------------------------------------------------------------------
-- 1) Raw hourly telemetry ingestion credits
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FACT_TELEMETRY_INGEST_HOUR (
  start_time                TIMESTAMP_LTZ,
  end_time                  TIMESTAMP_LTZ,
  entity_type               STRING,
  entity_id                 NUMBER,
  name                      STRING,
  database_name             STRING,
  schema_name               STRING,
  credits_used_compute      NUMBER,
  credits_used_cloud_services NUMBER,
  credits_used              NUMBER,
  extracted_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_tel_ingest_hour UNIQUE (start_time, end_time, COALESCE(entity_type,''), COALESCE(entity_id,-1), COALESCE(name,''))
);

CREATE OR REPLACE VIEW V_TELEMETRY_INGEST_HOURLY AS
SELECT
  start_time,
  end_time,
  entity_type,
  entity_id,
  name,
  database_name,
  schema_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE service_type = 'TELEMETRY_DATA_INGEST';

-- ----------------------------------------------------------------------------
-- 2) Hourly event volume by app dimensions (from EVENTS_VIEW)
-- ----------------------------------------------------------------------------
-- IMPORTANT: The exact RESOURCE_ATTRIBUTES keys vary. These are the keys we've been using elsewhere in our drafts;
-- validate in a real consumer account + Native App runtime.
CREATE OR REPLACE VIEW V_EVENT_VOLUME_APP_HOURLY AS
SELECT
  DATE_TRUNC('hour', TIMESTAMP) AS hour_start,
  RESOURCE_ATTRIBUTES:"snow.application.package.name"::string        AS app_package,
  RESOURCE_ATTRIBUTES:"snow.application.version"::string             AS app_version,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.organization"::string AS consumer_org,
  RESOURCE_ATTRIBUTES:"snow.application.consumer.name"::string       AS consumer_name,
  RECORD_TYPE::string AS record_type,
  COUNT(*) AS events
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
GROUP BY 1,2,3,4,5,6;

-- ----------------------------------------------------------------------------
-- 3) Allocate TELEMETRY_DATA_INGEST credits to app dims (proportional by event volume)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FACT_TELEMETRY_INGEST_APP_HOUR (
  hour_start                TIMESTAMP_LTZ,
  app_package               STRING,
  app_version               STRING,
  consumer_org              STRING,
  consumer_name             STRING,
  events_total              NUMBER,
  credits_used              NUMBER,
  allocation_method         STRING,
  extracted_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_tel_ingest_app_hour UNIQUE (hour_start, COALESCE(app_package,''), COALESCE(app_version,''), COALESCE(consumer_org,''), COALESCE(consumer_name,''))
);

-- Allocation view:
-- - Compute total telemetry ingestion credits per hour.
-- - Compute total event volume per hour.
-- - Allocate credits to each (app_package/app_version/consumer) proportional to events.
CREATE OR REPLACE VIEW V_TELEMETRY_INGEST_CREDITS_BY_APP_HOUR AS
WITH ingest AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start,
    SUM(credits_used) AS credits_used
  FROM V_TELEMETRY_INGEST_HOURLY
  GROUP BY 1
),
vol AS (
  SELECT
    hour_start,
    app_package,
    app_version,
    consumer_org,
    consumer_name,
    SUM(events) AS events
  FROM V_EVENT_VOLUME_APP_HOURLY
  GROUP BY 1,2,3,4,5
),
vol_tot AS (
  SELECT hour_start, SUM(events) AS events_total
  FROM vol
  GROUP BY 1
)
SELECT
  v.hour_start,
  v.app_package,
  v.app_version,
  v.consumer_org,
  v.consumer_name,
  t.events_total,
  i.credits_used * (v.events / NULLIF(t.events_total, 0)) AS credits_used,
  'PROPORTIONAL_BY_EVENT_COUNT' AS allocation_method
FROM vol v
JOIN vol_tot t
  ON v.hour_start = t.hour_start
JOIN ingest i
  ON v.hour_start = i.hour_start;

-- ----------------------------------------------------------------------------
-- 4) Refresh procedure (idempotent MERGE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_REFRESH_TELEMETRY_INGEST_COST_ATTR(lookback_hours NUMBER)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- 4a) Ingest raw hourly cost rows
  MERGE INTO FACT_TELEMETRY_INGEST_HOUR t
  USING (
    SELECT *
    FROM V_TELEMETRY_INGEST_HOURLY
    WHERE start_time >= DATEADD('hour', -lookback_hours, CURRENT_TIMESTAMP())
  ) s
  ON t.start_time = s.start_time
     AND t.end_time = s.end_time
     AND COALESCE(t.entity_type,'') = COALESCE(s.entity_type,'')
     AND COALESCE(t.entity_id,-1) = COALESCE(s.entity_id,-1)
     AND COALESCE(t.name,'') = COALESCE(s.name,'')
  WHEN MATCHED THEN UPDATE SET
    database_name = s.database_name,
    schema_name = s.schema_name,
    credits_used_compute = s.credits_used_compute,
    credits_used_cloud_services = s.credits_used_cloud_services,
    credits_used = s.credits_used,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    start_time, end_time, entity_type, entity_id, name,
    database_name, schema_name,
    credits_used_compute, credits_used_cloud_services, credits_used
  ) VALUES (
    s.start_time, s.end_time, s.entity_type, s.entity_id, s.name,
    s.database_name, s.schema_name,
    s.credits_used_compute, s.credits_used_cloud_services, s.credits_used
  );

  -- 4b) Allocate to app dims
  MERGE INTO FACT_TELEMETRY_INGEST_APP_HOUR t
  USING (
    SELECT
      hour_start,
      app_package,
      app_version,
      consumer_org,
      consumer_name,
      events_total,
      credits_used,
      allocation_method
    FROM V_TELEMETRY_INGEST_CREDITS_BY_APP_HOUR
    WHERE hour_start >= DATEADD('hour', -lookback_hours, CURRENT_TIMESTAMP())
  ) s
  ON t.hour_start = s.hour_start
     AND COALESCE(t.app_package,'') = COALESCE(s.app_package,'')
     AND COALESCE(t.app_version,'') = COALESCE(s.app_version,'')
     AND COALESCE(t.consumer_org,'') = COALESCE(s.consumer_org,'')
     AND COALESCE(t.consumer_name,'') = COALESCE(s.consumer_name,'')
  WHEN MATCHED THEN UPDATE SET
    events_total = s.events_total,
    credits_used = s.credits_used,
    allocation_method = s.allocation_method,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    hour_start, app_package, app_version, consumer_org, consumer_name,
    events_total, credits_used, allocation_method
  ) VALUES (
    s.hour_start, s.app_package, s.app_version, s.consumer_org, s.consumer_name,
    s.events_total, s.credits_used, s.allocation_method
  );

  RETURN 'ok';
END;
$$;

-- ----------------------------------------------------------------------------
-- 5) (Optional) Task wrapper
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE TASK TASK_REFRESH_TELEMETRY_INGEST_COST_ATTR
--   WAREHOUSE = '<SET_WAREHOUSE>'
--   SCHEDULE = '60 MINUTE'
-- AS
--   CALL SP_REFRESH_TELEMETRY_INGEST_COST_ATTR(lookback_hours => 24);

-- End draft.
