-- FinOps Native App — Phase 0: Idle Warehouse Detection + Recommendations (preview-first)
-- Date: 2026-02-20
-- Author: Snow
--
-- Goal:
--   Implement the minimal “detect → explain → recommend → (optionally) remediate” loop for idle warehouse credits.
--
-- Guardrails (per Akhil):
--   1) Remediation is opt-in + preview-first (generate ALTER SQL by default; apply is optional/feature-flagged)
--   2) Idle credits model uses canonical columns from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY:
--        idle_credits = CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES (clamp at 0)
--      Fallback attribution sources are NOT implemented in Phase 0 (documented as follow-up).
--
-- Assumptions / Notes:
--   - ACCOUNT_USAGE latency is expected (typically ~2-3 hours). This is for daily / near-real-time guidance, not minute-by-minute.
--   - Warehouse configuration is sourced from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES (documented availability varies by account/edition).
--   - All objects are created under schema FINOPS (adjust for your app-owned DB/schema conventions).

-- =============================================================================
-- A) Schema + config tables
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS FINOPS;

CREATE TABLE IF NOT EXISTS FINOPS.CFG_WAREHOUSE_ALLOWLIST (
  warehouse_name STRING,
  active         BOOLEAN DEFAULT TRUE,
  note           STRING,
  updated_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_cfg_wh_allow UNIQUE (warehouse_name)
);

CREATE TABLE IF NOT EXISTS FINOPS.CFG_WAREHOUSE_DENYLIST (
  warehouse_name STRING,
  active         BOOLEAN DEFAULT TRUE,
  note           STRING,
  updated_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_cfg_wh_deny UNIQUE (warehouse_name)
);

CREATE TABLE IF NOT EXISTS FINOPS.CFG_FINOPS_PARAMS (
  param_name  STRING,
  param_value STRING,
  updated_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_cfg_params UNIQUE (param_name)
);

-- Seed defaults (idempotent)
MERGE INTO FINOPS.CFG_FINOPS_PARAMS t
USING (
  SELECT 'AUTO_SUSPEND_AGGRESSIVE_SECS' AS param_name, '60' AS param_value UNION ALL
  SELECT 'IDLE_RECO_MIN_IDLE_CREDITS_7D', '5' UNION ALL
  SELECT 'CREDIT_PRICE_USD', NULL
) s
ON t.param_name = s.param_name
WHEN NOT MATCHED THEN
  INSERT (param_name, param_value) VALUES (s.param_name, s.param_value);

-- Convenience: params as a single row (avoid repeated scalar subqueries)
CREATE OR REPLACE VIEW FINOPS.V_FINOPS_PARAMS AS
SELECT
  TRY_TO_NUMBER(MAX(IFF(param_name = 'AUTO_SUSPEND_AGGRESSIVE_SECS', param_value, NULL))) AS auto_suspend_aggressive_secs,
  TRY_TO_NUMBER(MAX(IFF(param_name = 'IDLE_RECO_MIN_IDLE_CREDITS_7D', param_value, NULL))) AS idle_reco_min_idle_credits_7d,
  TRY_TO_NUMBER(MAX(IFF(param_name = 'CREDIT_PRICE_USD', param_value, NULL))) AS credit_price_usd
FROM FINOPS.CFG_FINOPS_PARAMS;

-- =============================================================================
-- B) Views
-- =============================================================================

-- 1) Core 7-day idle computation
CREATE OR REPLACE VIEW FINOPS.FINOPS_IDLE_WAREHOUSE_7D_VW AS
WITH params AS (
  SELECT * FROM FINOPS.V_FINOPS_PARAMS
),
wmh_7d AS (
  SELECT
    wmh.WAREHOUSE_NAME AS warehouse_name,
    SUM(wmh.CREDITS_USED_COMPUTE) AS credits_used_compute_7d,
    SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES) AS credits_attributed_compute_queries_7d,
    MAX(wmh.START_TIME)::TIMESTAMP_NTZ AS last_metered_hour
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  WHERE wmh.START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  GROUP BY 1
),
wh_cfg AS (
  -- NOTE: If this view is unavailable in some environments, we can replace it with a proc-built snapshot table.
  SELECT
    warehouse_name,
    auto_suspend,
    auto_resume,
    warehouse_size,
    state
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES
)
SELECT
  m.warehouse_name,

  m.credits_used_compute_7d,
  m.credits_attributed_compute_queries_7d,

  /* canonical idle gap (clamped) */
  GREATEST(m.credits_used_compute_7d - m.credits_attributed_compute_queries_7d, 0) AS idle_credits_7d,

  /* ratio */
  ROUND(
    GREATEST(m.credits_used_compute_7d - m.credits_attributed_compute_queries_7d, 0)
      / NULLIF(m.credits_used_compute_7d, 0),
    6
  ) AS idle_pct_7d,

  m.last_metered_hour,
  DATEDIFF('hour', m.last_metered_hour, CURRENT_TIMESTAMP()) AS hours_since_last_metered,

  /* warehouse config (best-effort) */
  c.auto_suspend,
  c.auto_resume,
  c.warehouse_size,
  c.state AS warehouse_state,

  'ACCOUNT_USAGE is delayed (often ~2-3h); use as directional signal' AS data_latency_note
FROM wmh_7d m
LEFT JOIN wh_cfg c
  ON UPPER(m.warehouse_name) = UPPER(c.warehouse_name);


-- 2) Recommendations view (safety rules + explainability)
CREATE OR REPLACE VIEW FINOPS.FINOPS_IDLE_WAREHOUSE_RECOS_VW AS
WITH params AS (
  SELECT * FROM FINOPS.V_FINOPS_PARAMS
),
allowlist_active AS (
  SELECT UPPER(warehouse_name) AS warehouse_name
  FROM FINOPS.CFG_WAREHOUSE_ALLOWLIST
  WHERE active
),
denylist_active AS (
  SELECT UPPER(warehouse_name) AS warehouse_name
  FROM FINOPS.CFG_WAREHOUSE_DENYLIST
  WHERE active
),
allowlist_stats AS (
  SELECT COUNT(*) AS allowlist_active_cnt FROM allowlist_active
)
SELECT
  v.warehouse_name,
  v.credits_used_compute_7d,
  v.credits_attributed_compute_queries_7d,
  v.idle_credits_7d,
  v.idle_pct_7d,
  v.last_metered_hour,
  v.hours_since_last_metered,
  v.auto_suspend,
  v.auto_resume,
  v.warehouse_size,
  v.warehouse_state,

  /* Safety: allow/deny */
  IFF(d.warehouse_name IS NOT NULL, TRUE, FALSE) AS is_denylisted,
  IFF(a.warehouse_name IS NOT NULL, TRUE, FALSE) AS is_allowlisted,

  /* Allow logic:
     - If allowlist has any active rows, only allow allowlisted warehouses.
     - If allowlist empty, allow all (unless denylisted).
  */
  IFF(
    (SELECT allowlist_active_cnt FROM allowlist_stats) > 0,
    (a.warehouse_name IS NOT NULL),
    TRUE
  ) AS allowlist_pass,

  /* Suppression rules */
  IFF(
    COALESCE(v.auto_suspend, 999999) <= (SELECT auto_suspend_aggressive_secs FROM params),
    TRUE,
    FALSE
  ) AS is_already_aggressive,

  IFF(
    v.idle_credits_7d < (SELECT idle_reco_min_idle_credits_7d FROM params),
    TRUE,
    FALSE
  ) AS is_below_idle_threshold,

  /* Recommended setting (Phase 0: recommend aggressive threshold) */
  (SELECT auto_suspend_aggressive_secs FROM params) AS recommended_auto_suspend_secs,

  /* Conservative savings estimate (Phase 0): idle credits ~= opportunity */
  v.idle_credits_7d AS est_savings_credits_7d,
  IFF(
    (SELECT credit_price_usd FROM params) IS NULL,
    NULL,
    v.idle_credits_7d * (SELECT credit_price_usd FROM params)
  ) AS est_savings_usd_7d,

  /* Deterministic reason string for UI */
  CASE
    WHEN d.warehouse_name IS NOT NULL THEN 'SUPPRESSED: denylisted'
    WHEN NOT IFF((SELECT allowlist_active_cnt FROM allowlist_stats) > 0, (a.warehouse_name IS NOT NULL), TRUE)
      THEN 'SUPPRESSED: not allowlisted'
    WHEN v.credits_used_compute_7d IS NULL OR v.credits_used_compute_7d = 0 THEN 'SUPPRESSED: no compute usage in last 7d'
    WHEN v.idle_credits_7d < (SELECT idle_reco_min_idle_credits_7d FROM params) THEN 'SUPPRESSED: idle credits below threshold'
    WHEN COALESCE(v.auto_suspend, 999999) <= (SELECT auto_suspend_aggressive_secs FROM params) THEN 'SUPPRESSED: already auto-suspending aggressively'
    ELSE 'RECOMMEND: set AUTO_SUSPEND to aggressive threshold'
  END AS recommendation_reason,

  /* Eligible = passes all suppression rules */
  IFF(
    d.warehouse_name IS NULL
    AND IFF((SELECT allowlist_active_cnt FROM allowlist_stats) > 0, (a.warehouse_name IS NOT NULL), TRUE)
    AND COALESCE(v.credits_used_compute_7d, 0) > 0
    AND v.idle_credits_7d >= (SELECT idle_reco_min_idle_credits_7d FROM params)
    AND COALESCE(v.auto_suspend, 999999) > (SELECT auto_suspend_aggressive_secs FROM params),
    TRUE,
    FALSE
  ) AS is_actionable,

  v.data_latency_note
FROM FINOPS.FINOPS_IDLE_WAREHOUSE_7D_VW v
LEFT JOIN allowlist_active a
  ON UPPER(v.warehouse_name) = a.warehouse_name
LEFT JOIN denylist_active d
  ON UPPER(v.warehouse_name) = d.warehouse_name;

-- =============================================================================
-- C) Stored procedures (preview-first)
-- =============================================================================

CREATE OR REPLACE PROCEDURE FINOPS.SP_GENERATE_WAREHOUSE_AUTOSUSPEND_SQL(warehouse_name STRING)
RETURNS TABLE (sql_text STRING, why STRING, assumptions STRING)
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  RETURN TABLE(
    WITH r AS (
      SELECT *
      FROM FINOPS.FINOPS_IDLE_WAREHOUSE_RECOS_VW
      WHERE UPPER(warehouse_name) = UPPER(:warehouse_name)
      QUALIFY ROW_NUMBER() OVER (ORDER BY idle_credits_7d DESC) = 1
    )
    SELECT
      IFF(
        r.is_actionable,
        'ALTER WAREHOUSE ' || IDENTIFIER(r.warehouse_name) || ' SET AUTO_SUSPEND = ' || r.recommended_auto_suspend_secs || ';',
        NULL
      ) AS sql_text,
      IFF(
        r.is_actionable,
        'Idle compute credits detected over trailing 7d; recommend lowering AUTO_SUSPEND to reduce idle burn.',
        COALESCE(r.recommendation_reason, 'No recommendation available for this warehouse')
      ) AS why,
      'ACCOUNT_USAGE latency (~2-3h). Savings estimate is conservative: est_savings_credits_7d ~= idle_credits_7d. Apply changes only after confirming workload tolerance.' AS assumptions
    FROM r

    UNION ALL

    -- If warehouse not found in recos view, return a single "no action" row
    SELECT
      NULL AS sql_text,
      'No data found for warehouse in trailing 7d (or insufficient privileges to read metering/config views).' AS why,
      'If ACCOUNT_USAGE views are restricted, run provider-side or request consumer role grants. Fallback attribution sources (QUERY_ATTRIBUTION_HISTORY / QUERY_HISTORY) are a follow-up.' AS assumptions
    WHERE NOT EXISTS (
      SELECT 1
      FROM FINOPS.FINOPS_IDLE_WAREHOUSE_RECOS_VW
      WHERE UPPER(warehouse_name) = UPPER(:warehouse_name)
    )
  );
END;
$$;

-- Optional Phase 0.5 (NOT enabled here): apply procedure with strict role + confirmation.
-- Create behind a feature flag + dedicated app role (e.g. FINOPS_ADMIN).
--
-- CREATE OR REPLACE PROCEDURE FINOPS.SP_APPLY_WAREHOUSE_AUTOSUSPEND(
--   warehouse_name STRING,
--   secs NUMBER,
--   confirm BOOLEAN
-- )
-- RETURNS VARIANT
-- LANGUAGE SQL
-- EXECUTE AS OWNER
-- AS
-- $$
-- DECLARE
--   v_sql STRING;
-- BEGIN
--   IF (confirm IS NULL OR confirm = FALSE) THEN
--     RETURN OBJECT_CONSTRUCT('status','blocked','reason','confirm must be TRUE');
--   END IF;
--
--   -- Hard denylist check
--   IF EXISTS (
--     SELECT 1 FROM FINOPS.CFG_WAREHOUSE_DENYLIST
--     WHERE active AND UPPER(warehouse_name) = UPPER(:warehouse_name)
--   ) THEN
--     RETURN OBJECT_CONSTRUCT('status','blocked','reason','warehouse denylisted');
--   END IF;
--
--   v_sql := 'ALTER WAREHOUSE ' || IDENTIFIER(:warehouse_name) || ' SET AUTO_SUSPEND = ' || secs || ';';
--   EXECUTE IMMEDIATE v_sql;
--
--   RETURN OBJECT_CONSTRUCT('status','ok','sql',v_sql);
-- END;
-- $$;

-- =============================================================================
-- D) Minimal validation queries (manual)
-- =============================================================================
--
-- -- Top actionable candidates
-- SELECT *
-- FROM FINOPS.FINOPS_IDLE_WAREHOUSE_RECOS_VW
-- WHERE is_actionable
-- ORDER BY est_savings_credits_7d DESC;
--
-- -- Generate SQL for a specific warehouse
-- CALL FINOPS.SP_GENERATE_WAREHOUSE_AUTOSUSPEND_SQL('MY_WAREHOUSE');
--
-- End.
