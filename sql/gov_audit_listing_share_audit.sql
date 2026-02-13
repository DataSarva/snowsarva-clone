-- GOV_AUDIT: Listing/Share audit + drift (Native App friendly)
-- Date: 2026-02-13
-- Goal (v0): provider-side audit tables + refresh stored procedure to snapshot + diff:
--   1) Listing inventory + drift
--   2) Share/grant change summary
--
-- Assumptions:
-- - Runs in an owner’s-rights context inside a Native App.
-- - INFORMATION_SCHEMA.LISTINGS is available (provider inventory).
-- - ACCOUNT_USAGE views (LISTINGS/SHARES/GRANTS_TO_SHARES) may be available with latency; code should fail-soft.
-- - We prefer “tables for UI” over multi-result-set procedures to keep integration simple.

-- =========================
-- 0) Schema
-- =========================
CREATE SCHEMA IF NOT EXISTS GOV_AUDIT;

-- =========================
-- 1) Snapshot tables
-- =========================

-- Current + historical snapshots of listings.
-- Use SCD2-ish validity (valid_from/valid_to) so drift is easy to query.
CREATE TABLE IF NOT EXISTS GOV_AUDIT.FACT_LISTING_SNAPSHOT (
  listing_name           STRING,
  listing_global_name    STRING,
  listing_owner          STRING,
  listing_state          STRING,
  listing_type           STRING,
  target_accounts        VARIANT,
  created_on             TIMESTAMP_NTZ,
  last_altered           TIMESTAMP_NTZ,
  raw                   VARIANT,

  -- SCD2 validity
  valid_from             TIMESTAMP_NTZ,
  valid_to               TIMESTAMP_NTZ,
  is_current             BOOLEAN,

  extracted_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

  CONSTRAINT uq_listing_snapshot UNIQUE (listing_name, valid_from)
);

-- Grants-to-shares snapshot (enables drift detection on share access).
CREATE TABLE IF NOT EXISTS GOV_AUDIT.FACT_SHARE_GRANT_SNAPSHOT (
  share_name             STRING,
  granted_on             STRING, -- e.g. DATABASE, SCHEMA, TABLE, VIEW, FUNCTION, etc.
  name                   STRING, -- object name or identifier
  privilege              STRING,
  granted_to             STRING,
  grantee_name           STRING,
  grant_option           BOOLEAN,
  granted_by             STRING,
  created_on             TIMESTAMP_NTZ,
  raw                   VARIANT,

  -- SCD2 validity
  valid_from             TIMESTAMP_NTZ,
  valid_to               TIMESTAMP_NTZ,
  is_current             BOOLEAN,

  extracted_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

  CONSTRAINT uq_share_grant_snapshot UNIQUE (share_name, granted_on, name, privilege, grantee_name, valid_from)
);

-- =========================
-- 2) Diff tables (UI-ready)
-- =========================

-- One row per change event between refreshes.
CREATE TABLE IF NOT EXISTS GOV_AUDIT.FACT_LISTING_DIFF (
  diff_at                TIMESTAMP_NTZ,
  listing_name           STRING,
  change_type            STRING,   -- ADDED | REMOVED | UPDATED
  changed_fields         ARRAY,    -- e.g. ["listing_state","target_accounts"]
  before                VARIANT,
  after                 VARIANT,
  extracted_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS GOV_AUDIT.FACT_SHARE_GRANT_DIFF (
  diff_at                TIMESTAMP_NTZ,
  share_name             STRING,
  change_type            STRING,   -- ADDED | REMOVED | UPDATED
  key                    STRING,   -- stable key string for UI (constructed)
  before                VARIANT,
  after                 VARIANT,
  extracted_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =========================
-- 3) Refresh procedure
-- =========================

-- SQL stored proc skeleton. Implementation notes:
-- - Snowflake SQL procedures can use scripting blocks (DECLARE/BEGIN/END).
-- - For fail-soft on ACCOUNT_USAGE: wrap in EXECUTE IMMEDIATE inside TRY/CATCH (SQL scripting supports EXCEPTION).
-- - For drift detection: compute a deterministic hash over relevant fields, compare to current snapshot.
--
-- TODO for PR:
-- - Finalize exact columns from INFORMATION_SCHEMA.LISTINGS (depends on actual view definition).
-- - Finalize exact columns from ACCOUNT_USAGE.GRANTS_TO_SHARES.
-- - Add hashing + MERGE logic.

CREATE OR REPLACE PROCEDURE GOV_AUDIT.SP_REFRESH_LISTING_SHARE_AUDIT(since_ts TIMESTAMP_NTZ)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_now TIMESTAMP_NTZ;
  v_result VARIANT;
BEGIN
  v_now := CURRENT_TIMESTAMP();

  -- 1) LISTINGS snapshot refresh (INFO_SCHEMA)
  -- Staging query: adapt to actual column names available.
  -- Recommended: capture full row as VARIANT for forward-compat.
  CREATE OR REPLACE TEMP TABLE _stg_listings AS
  SELECT
    listing_name,
    listing_global_name,
    listing_owner,
    listing_state,
    listing_type,
    target_accounts,
    created_on,
    last_altered,
    OBJECT_CONSTRUCT(*) AS raw
  FROM INFORMATION_SCHEMA.LISTINGS;

  -- TODO: MERGE into FACT_LISTING_SNAPSHOT with SCD2 validity.
  -- Steps (high level):
  --   a) End-date current rows that changed/removed (set valid_to=v_now, is_current=false)
  --   b) Insert new current rows for added/changed (valid_from=v_now, valid_to=NULL, is_current=true)
  --   c) Insert FACT_LISTING_DIFF rows for each delta

  -- 2) SHARE/GRANT snapshot refresh (ACCOUNT_USAGE)
  -- Fail-soft if view unavailable.
  BEGIN
    CREATE OR REPLACE TEMP TABLE _stg_share_grants AS
    SELECT
      share_name,
      granted_on,
      name,
      privilege,
      granted_to,
      grantee_name,
      grant_option,
      granted_by,
      created_on,
      OBJECT_CONSTRUCT(*) AS raw
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES
    WHERE created_on >= COALESCE(since_ts, DATEADD('day', -30, v_now));

    -- TODO: MERGE into FACT_SHARE_GRANT_SNAPSHOT + emit FACT_SHARE_GRANT_DIFF
  EXCEPTION
    WHEN OTHER THEN
      -- swallow; keep procedure useful even when ACCOUNT_USAGE is restricted
      NULL;
  END;

  v_result := OBJECT_CONSTRUCT(
    'refreshed_at', v_now,
    'since_ts', since_ts,
    'notes', ARRAY_CONSTRUCT(
      'v0 skeleton created: implement MERGE + diff logic next',
      'ACCOUNT_USAGE section is fail-soft; will no-op if view missing'
    )
  );

  RETURN v_result;
END;
$$;

-- =========================
-- 4) Convenience views (optional)
-- =========================

CREATE OR REPLACE VIEW GOV_AUDIT.V_LISTINGS_CURRENT AS
SELECT *
FROM GOV_AUDIT.FACT_LISTING_SNAPSHOT
WHERE is_current;

CREATE OR REPLACE VIEW GOV_AUDIT.V_SHARE_GRANTS_CURRENT AS
SELECT *
FROM GOV_AUDIT.FACT_SHARE_GRANT_SNAPSHOT
WHERE is_current;
