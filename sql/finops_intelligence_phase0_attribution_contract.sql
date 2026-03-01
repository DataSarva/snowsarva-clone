-- FinOps Native App — Phase 0: Attribution-ready fact tables ("truth spine")
-- Date: 2026-03-01
-- Author: Snow
--
-- Goal:
--   Establish durable, UI-friendly fact tables that normalize:
--     1) Hourly warehouse usage (ACCOUNT_USAGE)
--     2) Daily billed credits + currency (ORG_USAGE where available)
--     3) Daily allocation to (warehouse, query_tag) with explicit allocation method + caveats
--
-- Product guarantees (per Akhil):
--   - “Billed truth” comes from METERING_DAILY_HISTORY / currency views (ORG_USAGE preferred; fall back may be disabled).
--   - Anything mapped to (warehouse, query_tag) is ALLOCATION. We persist method + notes.
--
-- Important notes:
--   - ACCOUNT_USAGE/ORG_USAGE views have latency. Do not treat current day as final.
--   - Query attribution differs by availability. We try QUERY_ATTRIBUTION_HISTORY first; else QUERY_HISTORY proxy.
--   - All timestamps are normalized to UTC.

-- =============================================================================
-- 0) Schema
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS FINOPS_INTELLIGENCE;

-- =============================================================================
-- 1) Core fact tables
-- =============================================================================

-- 1.1) Hourly warehouse usage (account-level)
CREATE TABLE IF NOT EXISTS FINOPS_INTELLIGENCE.FACT_WAREHOUSE_HOUR (
  usage_hour                           TIMESTAMP_NTZ,  -- UTC hour start
  warehouse_name                       STRING,

  credits_used_compute                 NUMBER(38,9),
  credits_attributed_compute_queries   NUMBER(38,9),
  credits_used_cloud_services          NUMBER(38,9),
  credits_used                         NUMBER(38,9),

  idle_credits                         NUMBER(38,9),  -- GREATEST(credits_used_compute - credits_attributed_compute_queries, 0)

  -- Explainability / raw lineage
  raw                                  VARIANT,

  extracted_at                         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

  CONSTRAINT uq_fact_warehouse_hour UNIQUE (usage_hour, warehouse_name)
);

-- 1.2) Daily billed credits (+ currency when available) (org-level "truth")
CREATE TABLE IF NOT EXISTS FINOPS_INTELLIGENCE.FACT_BILLED_DAY (
  usage_date                           DATE,          -- UTC day
  service_type                         STRING,        -- from ORG_USAGE.METERING_DAILY_HISTORY

  billed_credits                       NUMBER(38,9),

  -- Optional currency layer (may be unavailable or delayed)
  billed_currency_amount               NUMBER(38,9),
  currency                             STRING,

  -- Explainability
  raw_metering                         VARIANT,
  raw_currency                         VARIANT,

  extracted_at                         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

  CONSTRAINT uq_fact_billed_day UNIQUE (usage_date, service_type)
);

-- 1.3) Daily allocation to (warehouse, query_tag)
CREATE TABLE IF NOT EXISTS FINOPS_INTELLIGENCE.FACT_WAREHOUSE_QUERY_TAG_DAY (
  usage_date                           DATE,
  warehouse_name                       STRING,
  query_tag                            STRING,

  query_credits                        NUMBER(38,9),  -- from attribution/proxy
  idle_credits_allocated               NUMBER(38,9),
  total_credits_allocated              NUMBER(38,9),  -- query_credits + idle_credits_allocated

  -- Heuristic allocations (must be labeled)
  billed_credits_allocated             NUMBER(38,9),
  billed_currency_allocated            NUMBER(38,9),

  allocation_method                    STRING,         -- QUERY_ATTRIBUTION | QUERY_HISTORY_PROXY | IDLE_PROPORTIONAL | BILLED_PROPORTIONAL
  notes                                VARIANT,

  extracted_at                         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

  CONSTRAINT uq_fact_wh_qtag_day UNIQUE (usage_date, warehouse_name, query_tag)
);

-- =============================================================================
-- 2) Refresh procedure + daily task
-- =============================================================================

-- SP_REFRESH_FACTS(lookback_days)
-- Idempotent: MERGE into each fact for the given window.
CREATE OR REPLACE PROCEDURE FINOPS_INTELLIGENCE.SP_REFRESH_FACTS(lookback_days NUMBER)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_now                 TIMESTAMP_NTZ;
  v_start_hour          TIMESTAMP_NTZ;
  v_start_date          DATE;

  v_used_query_attrib   BOOLEAN DEFAULT FALSE;
  v_has_org_metering    BOOLEAN DEFAULT FALSE;
  v_has_currency        BOOLEAN DEFAULT FALSE;

  v_result              VARIANT;
BEGIN
  v_now := CURRENT_TIMESTAMP();

  -- Normalize to UTC for ACCOUNT_USAGE reconciliation (per Snowflake docs)
  ALTER SESSION SET TIMEZONE = 'UTC';

  v_start_hour := DATE_TRUNC('hour', DATEADD('day', -lookback_days, v_now));
  v_start_date := DATEADD('day', -lookback_days, CURRENT_DATE());

  -- ---------------------------------------------------------------------------
  -- 2.1) FACT_WAREHOUSE_HOUR
  -- ---------------------------------------------------------------------------
  MERGE INTO FINOPS_INTELLIGENCE.FACT_WAREHOUSE_HOUR t
  USING (
    SELECT
      DATE_TRUNC('hour', wmh.START_TIME)::TIMESTAMP_NTZ AS usage_hour,
      wmh.WAREHOUSE_NAME::STRING AS warehouse_name,
      SUM(wmh.CREDITS_USED_COMPUTE) AS credits_used_compute,
      SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES) AS credits_attributed_compute_queries,
      SUM(wmh.CREDITS_USED_CLOUD_SERVICES) AS credits_used_cloud_services,
      SUM(wmh.CREDITS_USED) AS credits_used,
      GREATEST(
        SUM(wmh.CREDITS_USED_COMPUTE) - SUM(wmh.CREDITS_ATTRIBUTED_COMPUTE_QUERIES),
        0
      ) AS idle_credits,
      OBJECT_CONSTRUCT(
        'source', 'SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY',
        'window_start', v_start_hour,
        'refreshed_at', v_now
      ) AS raw
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
    WHERE wmh.START_TIME >= v_start_hour
    GROUP BY 1, 2
  ) s
  ON t.usage_hour = s.usage_hour
     AND t.warehouse_name = s.warehouse_name
  WHEN MATCHED THEN UPDATE SET
    credits_used_compute = s.credits_used_compute,
    credits_attributed_compute_queries = s.credits_attributed_compute_queries,
    credits_used_cloud_services = s.credits_used_cloud_services,
    credits_used = s.credits_used,
    idle_credits = s.idle_credits,
    raw = s.raw,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    usage_hour,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries,
    credits_used_cloud_services,
    credits_used,
    idle_credits,
    raw
  ) VALUES (
    s.usage_hour,
    s.warehouse_name,
    s.credits_used_compute,
    s.credits_attributed_compute_queries,
    s.credits_used_cloud_services,
    s.credits_used,
    s.idle_credits,
    s.raw
  );

  -- ---------------------------------------------------------------------------
  -- 2.2) FACT_BILLED_DAY (ORG_USAGE preferred)
  -- Fail-soft: if ORG_USAGE is unavailable, we leave FACT_BILLED_DAY unchanged.
  -- ---------------------------------------------------------------------------
  BEGIN
    EXECUTE IMMEDIATE $$
      SELECT 1
      FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
      LIMIT 1
    $$;
    v_has_org_metering := TRUE;
  EXCEPTION
    WHEN OTHER THEN
      v_has_org_metering := FALSE;
  END;

  BEGIN
    EXECUTE IMMEDIATE $$
      SELECT 1
      FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
      LIMIT 1
    $$;
    v_has_currency := TRUE;
  EXCEPTION
    WHEN OTHER THEN
      v_has_currency := FALSE;
  END;

  IF (v_has_org_metering) THEN
    -- Metering daily (credits billed)
    MERGE INTO FINOPS_INTELLIGENCE.FACT_BILLED_DAY t
    USING (
      SELECT
        mdh.USAGE_DATE::DATE AS usage_date,
        mdh.SERVICE_TYPE::STRING AS service_type,
        SUM(mdh.CREDITS_BILLED)::NUMBER(38,9) AS billed_credits,
        OBJECT_CONSTRUCT(
          'source', 'SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY',
          'refreshed_at', CURRENT_TIMESTAMP()
        ) AS raw_metering
      FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY mdh
      WHERE mdh.USAGE_DATE >= v_start_date
      GROUP BY 1,2
    ) s
    ON t.usage_date = s.usage_date AND t.service_type = s.service_type
    WHEN MATCHED THEN UPDATE SET
      billed_credits = s.billed_credits,
      raw_metering = s.raw_metering,
      extracted_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
      usage_date, service_type, billed_credits, raw_metering
    ) VALUES (
      s.usage_date, s.service_type, s.billed_credits, s.raw_metering
    );

    -- Currency daily (optional; best-effort)
    IF (v_has_currency) THEN
      MERGE INTO FINOPS_INTELLIGENCE.FACT_BILLED_DAY t
      USING (
        SELECT
          u.USAGE_DATE::DATE AS usage_date,
          -- We store currency at the same grain as service_type rows by joining later via date.
          -- In v0 we write currency onto the WAREHOUSE_METERING service_type row if present; else keep as NULL.
          'WAREHOUSE_METERING'::STRING AS service_type,
          SUM(IFF(u.IS_ADJUSTMENT, 0, u.USAGE_IN_CURRENCY))::NUMBER(38,9) AS billed_currency_amount,
          MAX(u.CURRENCY)::STRING AS currency,
          OBJECT_CONSTRUCT(
            'source', 'SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY',
            'note', 'v0: currency is summed (non-adjustments) and written to service_type=WAREHOUSE_METERING; feature-flag if needed',
            'refreshed_at', CURRENT_TIMESTAMP()
          ) AS raw_currency
        FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY u
        WHERE u.USAGE_DATE >= v_start_date
        GROUP BY 1
      ) s
      ON t.usage_date = s.usage_date AND t.service_type = s.service_type
      WHEN MATCHED THEN UPDATE SET
        billed_currency_amount = s.billed_currency_amount,
        currency = s.currency,
        raw_currency = s.raw_currency,
        extracted_at = CURRENT_TIMESTAMP()
      WHEN NOT MATCHED THEN INSERT (
        usage_date, service_type, billed_currency_amount, currency, raw_currency
      ) VALUES (
        s.usage_date, s.service_type, s.billed_currency_amount, s.currency, s.raw_currency
      );
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2.3) FACT_WAREHOUSE_QUERY_TAG_DAY
  -- Strategy:
  --   (a) compute daily query_credits by (date, warehouse, query_tag)
  --   (b) compute daily warehouse idle credits
  --   (c) allocate idle to tags proportional to query_credits share
  --   (d) allocate billed credits/currency heuristically:
  --       - day-level billed (service_type=WAREHOUSE_METERING) -> warehouses proportional to daily used credits
  --       - warehouse/day billed -> tags proportional to total_credits_allocated
  --
  -- If query attribution history is unavailable, we use QUERY_HISTORY proxy.
  -- ---------------------------------------------------------------------------

  BEGIN
    EXECUTE IMMEDIATE $$
      SELECT 1
      FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
      LIMIT 1
    $$;
    v_used_query_attrib := TRUE;
  EXCEPTION
    WHEN OTHER THEN
      v_used_query_attrib := FALSE;
  END;

  MERGE INTO FINOPS_INTELLIGENCE.FACT_WAREHOUSE_QUERY_TAG_DAY t
  USING (
    WITH wh_daily AS (
      SELECT
        DATE_TRUNC('day', usage_hour)::DATE AS usage_date,
        warehouse_name,
        SUM(COALESCE(credits_used_compute,0) + COALESCE(credits_used_cloud_services,0)) AS wh_used_credits_total,
        SUM(COALESCE(idle_credits,0)) AS wh_idle_credits
      FROM FINOPS_INTELLIGENCE.FACT_WAREHOUSE_HOUR
      WHERE usage_hour >= v_start_hour
      GROUP BY 1,2
    ),

    query_daily AS (
      SELECT * FROM (
        SELECT
          qh.usage_date,
          qh.warehouse_name,
          qh.query_tag,
          qh.query_credits,
          qh.allocation_method,
          qh.notes
        FROM (
          -- Branch A: QUERY_ATTRIBUTION_HISTORY (preferred)
          SELECT
            DATE_TRUNC('day', q.START_TIME)::DATE AS usage_date,
            q.WAREHOUSE_NAME::STRING AS warehouse_name,
            NULLIF(q.QUERY_TAG::STRING, '') AS query_tag,
            SUM(COALESCE(q.CREDITS_ATTRIBUTED_COMPUTE,0) + COALESCE(q.CREDITS_ATTRIBUTED_CLOUD_SERVICES,0)) AS query_credits,
            'QUERY_ATTRIBUTION'::STRING AS allocation_method,
            OBJECT_CONSTRUCT('source','SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY') AS notes
          FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY q
          WHERE q.START_TIME >= v_start_hour
            AND q.WAREHOUSE_NAME IS NOT NULL
          GROUP BY 1,2,3
        ) qh
        WHERE v_used_query_attrib

        UNION ALL

        SELECT
          DATE_TRUNC('day', qh.START_TIME)::DATE AS usage_date,
          qh.WAREHOUSE_NAME::STRING AS warehouse_name,
          NULLIF(qh.QUERY_TAG::STRING, '') AS query_tag,
          -- Proxy: query_history has cloud services credits; compute credits may not be present in all accounts.
          SUM(COALESCE(qh.CREDITS_USED_COMPUTE, 0) + COALESCE(qh.CREDITS_USED_CLOUD_SERVICES, 0)) AS query_credits,
          'QUERY_HISTORY_PROXY'::STRING AS allocation_method,
          OBJECT_CONSTRUCT('source','SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY', 'warning','proxy credits; not billed-adjusted') AS notes
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
        WHERE qh.START_TIME >= v_start_hour
          AND qh.WAREHOUSE_NAME IS NOT NULL
          AND NOT v_used_query_attrib
        GROUP BY 1,2,3
      )
      WHERE query_tag IS NOT NULL
    ),

    query_with_shares AS (
      SELECT
        q.usage_date,
        q.warehouse_name,
        q.query_tag,
        q.query_credits,
        w.wh_idle_credits,
        SUM(q.query_credits) OVER (PARTITION BY q.usage_date, q.warehouse_name) AS wh_query_credits_total,
        q.allocation_method,
        q.notes
      FROM query_daily q
      JOIN wh_daily w
        ON w.usage_date = q.usage_date
       AND w.warehouse_name = q.warehouse_name
    ),

    allocated AS (
      SELECT
        usage_date,
        warehouse_name,
        query_tag,
        query_credits,
        IFF(wh_query_credits_total = 0, 0,
            wh_idle_credits * (query_credits / wh_query_credits_total)
        ) AS idle_credits_allocated,
        (query_credits + IFF(wh_query_credits_total = 0, 0,
            wh_idle_credits * (query_credits / wh_query_credits_total)
        )) AS total_credits_allocated,
        allocation_method,
        notes
      FROM query_with_shares
    ),

    billed_day AS (
      SELECT
        usage_date,
        MAX(IFF(service_type = 'WAREHOUSE_METERING', billed_credits, NULL)) AS billed_credits_wh,
        MAX(IFF(service_type = 'WAREHOUSE_METERING', billed_currency_amount, NULL)) AS billed_currency_wh,
        MAX(currency) AS currency
      FROM FINOPS_INTELLIGENCE.FACT_BILLED_DAY
      WHERE usage_date >= v_start_date
      GROUP BY 1
    ),

    wh_used_tot AS (
      SELECT
        usage_date,
        SUM(wh_used_credits_total) AS acct_wh_used_total
      FROM wh_daily
      GROUP BY 1
    ),

    wh_billed_alloc AS (
      SELECT
        w.usage_date,
        w.warehouse_name,
        -- Allocate day-level billed credits down to warehouse/day proportional to used credits.
        IFF(t.acct_wh_used_total = 0, NULL,
            b.billed_credits_wh * (w.wh_used_credits_total / t.acct_wh_used_total)
        ) AS wh_billed_credits_allocated,
        IFF(t.acct_wh_used_total = 0, NULL,
            b.billed_currency_wh * (w.wh_used_credits_total / t.acct_wh_used_total)
        ) AS wh_billed_currency_allocated,
        b.currency
      FROM wh_daily w
      JOIN wh_used_tot t
        ON t.usage_date = w.usage_date
      LEFT JOIN billed_day b
        ON b.usage_date = w.usage_date
    ),

    tag_billed_alloc AS (
      SELECT
        a.usage_date,
        a.warehouse_name,
        a.query_tag,
        a.query_credits,
        a.idle_credits_allocated,
        a.total_credits_allocated,

        -- Allocate warehouse/day billed down to tags proportional to total credits allocated
        IFF(SUM(a.total_credits_allocated) OVER (PARTITION BY a.usage_date, a.warehouse_name) = 0, NULL,
            wba.wh_billed_credits_allocated
              * (a.total_credits_allocated / SUM(a.total_credits_allocated) OVER (PARTITION BY a.usage_date, a.warehouse_name))
        ) AS billed_credits_allocated,

        IFF(SUM(a.total_credits_allocated) OVER (PARTITION BY a.usage_date, a.warehouse_name) = 0, NULL,
            wba.wh_billed_currency_allocated
              * (a.total_credits_allocated / SUM(a.total_credits_allocated) OVER (PARTITION BY a.usage_date, a.warehouse_name))
        ) AS billed_currency_allocated,

        -- Allocation method chain (explicit)
        (a.allocation_method || '+IDLE_PROPORTIONAL+BILLED_PROPORTIONAL') AS allocation_method,
        OBJECT_CONSTRUCT(
          'query_attribution_method', a.allocation_method,
          'idle_allocation', 'IDLE_PROPORTIONAL',
          'billed_allocation', 'BILLED_PROPORTIONAL',
          'billed_truth_source', IFF(v_has_org_metering, 'ORG_USAGE.METERING_DAILY_HISTORY', NULL),
          'currency_source', IFF(v_has_currency, 'ORG_USAGE.USAGE_IN_CURRENCY_DAILY', NULL),
          'currency', wba.currency,
          'caveat', 'billed_credits_allocated/billed_currency_allocated are heuristic proportional allocations; not authoritative per-warehouse billing'
        ) AS notes
      FROM allocated a
      LEFT JOIN wh_billed_alloc wba
        ON wba.usage_date = a.usage_date
       AND wba.warehouse_name = a.warehouse_name
    )

    SELECT
      usage_date,
      warehouse_name,
      query_tag,
      query_credits,
      idle_credits_allocated,
      total_credits_allocated,
      billed_credits_allocated,
      billed_currency_allocated,
      allocation_method,
      notes
    FROM tag_billed_alloc
  ) s
  ON t.usage_date = s.usage_date
     AND t.warehouse_name = s.warehouse_name
     AND COALESCE(t.query_tag,'') = COALESCE(s.query_tag,'')
  WHEN MATCHED THEN UPDATE SET
    query_credits = s.query_credits,
    idle_credits_allocated = s.idle_credits_allocated,
    total_credits_allocated = s.total_credits_allocated,
    billed_credits_allocated = s.billed_credits_allocated,
    billed_currency_allocated = s.billed_currency_allocated,
    allocation_method = s.allocation_method,
    notes = s.notes,
    extracted_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    usage_date,
    warehouse_name,
    query_tag,
    query_credits,
    idle_credits_allocated,
    total_credits_allocated,
    billed_credits_allocated,
    billed_currency_allocated,
    allocation_method,
    notes
  ) VALUES (
    s.usage_date,
    s.warehouse_name,
    s.query_tag,
    s.query_credits,
    s.idle_credits_allocated,
    s.total_credits_allocated,
    s.billed_credits_allocated,
    s.billed_currency_allocated,
    s.allocation_method,
    s.notes
  );

  v_result := OBJECT_CONSTRUCT(
    'ok', TRUE,
    'refreshed_at', v_now,
    'lookback_days', lookback_days,
    'used_query_attribution_history', v_used_query_attrib,
    'has_org_metering', v_has_org_metering,
    'has_currency', v_has_currency
  );

  RETURN v_result;
END;
$$;

-- Daily task (optional). Commented by default so consumers can wire scheduling explicitly.
--
-- CREATE OR REPLACE TASK FINOPS_INTELLIGENCE.TASK_REFRESH_FACTS_DAILY
--   WAREHOUSE = <APP_TASK_WAREHOUSE>
--   SCHEDULE = 'USING CRON 30 2 * * * UTC'  -- 02:30 UTC daily (post-latency)
-- AS
--   CALL FINOPS_INTELLIGENCE.SP_REFRESH_FACTS(30);

-- =============================================================================
-- 3) Freshness view (UI safety)
-- =============================================================================

CREATE OR REPLACE VIEW FINOPS_INTELLIGENCE.V_FACT_FRESHNESS AS
WITH wh AS (
  SELECT
    'FACT_WAREHOUSE_HOUR' AS table_name,
    MAX(usage_hour) AS max_data_ts,
    MAX(extracted_at) AS last_refreshed_at,
    'ACCOUNT_USAGE (latency typically hours; cloud services cols may lag more)' AS notes
  FROM FINOPS_INTELLIGENCE.FACT_WAREHOUSE_HOUR
),
bd AS (
  SELECT
    'FACT_BILLED_DAY' AS table_name,
    MAX(usage_date)::TIMESTAMP_NTZ AS max_data_ts,
    MAX(extracted_at) AS last_refreshed_at,
    'ORG_USAGE (may be unavailable; currency latency can be up to ~72h)' AS notes
  FROM FINOPS_INTELLIGENCE.FACT_BILLED_DAY
),
qt AS (
  SELECT
    'FACT_WAREHOUSE_QUERY_TAG_DAY' AS table_name,
    MAX(usage_date)::TIMESTAMP_NTZ AS max_data_ts,
    MAX(extracted_at) AS last_refreshed_at,
    'Allocation facts; never present as authoritative billed cost at this grain' AS notes
  FROM FINOPS_INTELLIGENCE.FACT_WAREHOUSE_QUERY_TAG_DAY
)
SELECT * FROM wh
UNION ALL SELECT * FROM bd
UNION ALL SELECT * FROM qt;
