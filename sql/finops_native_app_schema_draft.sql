-- FinOps Native App — schema draft (provider or consumer install)
-- Date: 2026-02-01
-- Goal: minimal internal data model for (a) attribution config, (b) telemetry-derived facts, (c) recommendations tracking.
-- NOTE: This is a draft; tune datatypes + keys once we confirm Snowflake Native App storage/privilege patterns.

-- Suggested: place under an app-owned database/schema, e.g. APP_DB.APP_SCHEMA.

-- -----------------------------------------------------------------------------
-- 1) Attribution configuration (human-managed)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS DIM_COST_OWNER (
  owner_id            STRING,
  owner_name          STRING,
  owner_email         STRING,
  cost_center         STRING,
  org_unit            STRING,
  active              BOOLEAN DEFAULT TRUE,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at          TIMESTAMP_NTZ
);

-- Tag-based mapping (works well with governance tagging strategies)
CREATE TABLE IF NOT EXISTS MAP_TAG_TO_OWNER (
  tag_name            STRING,          -- e.g. 'COST_OWNER'
  tag_value           STRING,          -- e.g. 'data-platform'
  owner_id            STRING,
  priority            NUMBER(38,0) DEFAULT 100, -- lower = higher priority
  active              BOOLEAN DEFAULT TRUE,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at          TIMESTAMP_NTZ,
  CONSTRAINT uq_tag_owner UNIQUE (tag_name, tag_value)
);

-- Warehouse-based mapping (useful when tagging is missing)
CREATE TABLE IF NOT EXISTS MAP_WAREHOUSE_TO_OWNER (
  warehouse_name      STRING,
  owner_id            STRING,
  priority            NUMBER(38,0) DEFAULT 200,
  active              BOOLEAN DEFAULT TRUE,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at          TIMESTAMP_NTZ,
  CONSTRAINT uq_wh_owner UNIQUE (warehouse_name)
);

-- -----------------------------------------------------------------------------
-- 2) Curated usage facts (materialized from ACCOUNT_USAGE / ORG_USAGE)
-- -----------------------------------------------------------------------------

-- Daily warehouse spend + utilization (derive from METERING / WAREHOUSE_* usage sources)
CREATE TABLE IF NOT EXISTS FACT_WAREHOUSE_DAY (
  usage_date          DATE,
  warehouse_name      STRING,
  credits             NUMBER(38,9),
  cost_usd            NUMBER(38,9),
  avg_running         NUMBER(38,9),
  avg_queued          NUMBER(38,9),
  avg_blocked         NUMBER(38,9),
  avg_provisioning    NUMBER(38,9),
  source              STRING,  -- ACCOUNT_USAGE | ORG_USAGE | OTHER
  extracted_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_wh_day UNIQUE (usage_date, warehouse_name)
);

-- Daily “owner attribution” rollup (result of applying MAP_* rules)
CREATE TABLE IF NOT EXISTS FACT_OWNER_COST_DAY (
  usage_date          DATE,
  owner_id            STRING,
  cost_usd            NUMBER(38,9),
  credits             NUMBER(38,9),
  attribution_method  STRING,  -- TAG | WAREHOUSE | FALLBACK
  attribution_notes   STRING,
  extracted_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_owner_day UNIQUE (usage_date, owner_id, attribution_method)
);

-- -----------------------------------------------------------------------------
-- 3) Telemetry-derived facts (from Event Tables / EVENTS_VIEW)
-- -----------------------------------------------------------------------------

-- Standardize what we consider an "operation" so telemetry can be mapped to app features.
CREATE TABLE IF NOT EXISTS DIM_APP_OPERATION (
  operation_name      STRING,   -- e.g. 'finops.refresh_attribution'
  feature_area        STRING,   -- e.g. 'finops' | 'governance' | 'observability'
  description         STRING,
  active              BOOLEAN DEFAULT TRUE,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at          TIMESTAMP_NTZ,
  CONSTRAINT uq_operation UNIQUE (operation_name)
);

-- Configure telemetry levels to manage cost/volume.
CREATE TABLE IF NOT EXISTS CFG_TELEMETRY (
  scope              STRING,    -- 'consumer' | 'provider'
  level              STRING,    -- 'off' | 'errors' | 'standard' | 'verbose'
  sample_rate        NUMBER(5,4), -- 0..1
  retention_days     NUMBER(38,0),
  updated_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_telemetry_scope UNIQUE (scope)
);

-- Minimal “operation performance” fact table built from RECORD_TYPE='SPAN'
CREATE TABLE IF NOT EXISTS FACT_APP_OPERATION_WINDOW (
  window_start        TIMESTAMP_NTZ,
  window_end          TIMESTAMP_NTZ,
  app_package         STRING,
  app_version         STRING,
  operation_name      STRING,
  consumer_org        STRING,
  consumer_name       STRING,
  spans               NUMBER(38,0),
  errors              NUMBER(38,0),
  p50_ms              NUMBER(38,3),
  p95_ms              NUMBER(38,3),
  max_ms              NUMBER(38,3),
  extracted_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_app_op_window UNIQUE (window_start, app_package, app_version, operation_name, consumer_org, consumer_name)
);

-- Error log aggregation (RECORD_TYPE='LOG' + severity in WARN/ERROR/FATAL)
CREATE TABLE IF NOT EXISTS FACT_APP_ERROR_WINDOW (
  window_start        TIMESTAMP_NTZ,
  window_end          TIMESTAMP_NTZ,
  app_package         STRING,
  app_version         STRING,
  consumer_org        STRING,
  consumer_name       STRING,
  severity            STRING,
  message_fingerprint STRING, -- e.g. SHA1(normalized message) to dedupe
  message_sample      STRING,
  occurrences         NUMBER(38,0),
  extracted_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_app_err_window UNIQUE (window_start, app_package, app_version, consumer_org, consumer_name, severity, message_fingerprint)
);

-- -----------------------------------------------------------------------------
-- 4) Recommendation tracking (so we can measure impact)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS DIM_RECOMMENDATION (
  recommendation_id   STRING,
  kind                STRING,    -- e.g. WAREHOUSE_RIGHTSIZING | AUTO_SUSPEND | CLUSTERING | MATERIALIZATION
  title               STRING,
  description         STRING,
  severity            STRING,    -- INFO | WARN | CRITICAL
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at          TIMESTAMP_NTZ,
  active              BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS FACT_RECOMMENDATION_STATE (
  recommendation_id   STRING,
  as_of               TIMESTAMP_NTZ,
  target_type         STRING,    -- WAREHOUSE | DATABASE | SCHEMA | USER | ROLE
  target_name         STRING,
  owner_id            STRING,
  status              STRING,    -- NEW | ACKED | DISMISSED | APPLIED | EXPIRED
  estimated_savings_usd NUMBER(38,9),
  evidence            VARIANT,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_reco_state UNIQUE (recommendation_id, as_of, target_type, target_name)
);

-- End draft
