# FinOps Research Note — Cost forecasting + anomaly detection primitives for FinOps Native App

- **When (UTC):** 2026-02-03 03:16
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** The Native App needs *predictive* cost controls (forecast vs budget) and *proactive* detection (anomalies) that can run fully in-customer accounts with clear RBAC boundaries. Snowflake already exposes (a) Cost Management UI primitives (budgets + forecast) and (b) programmatic anomaly and ML primitives. We should integrate these rather than reinventing.

## Accurate takeaways
- Snowflake’s Cost Management Interface (Snowsight) includes organization + account level spend views; the account-level experience can **monitor account spend**, **forecast spend against budgets**, and highlight top spend drivers. It also surfaces “Budgets” as a first-class cost control. [Snowflake blog, 2024-08-19](https://www.snowflake.com/en/blog/cost-management-interface-generally-available/)
- Snowflake Budgets (GA per the same blog) monitor **compute credits** across **warehouses + serverless features** (e.g., auto-clustering, replication, search optimization) and provide improved email notifications. Budgets can be managed by roles with `BUDGET_ADMIN` / `BUDGET_VIEWER` (not only ACCOUNTADMIN). [Snowflake blog, 2024-08-19](https://www.snowflake.com/en/blog/cost-management-interface-generally-available/)
- Snowflake’s Well-Architected “Cost Optimization” guidance explicitly recommends a forecasting framework and calls out ACCOUNT_USAGE (incl. `WAREHOUSE_METERING_HISTORY`, `QUERY_HISTORY`) as baseline sources; it also recommends using built-in **SNOWFLAKE.ML forecast** for time-series forecasting and pairing anomaly detection with alerts/notifications for lower-level signals. [Snowflake Well-Architected Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
- Snowflake supports “Programmatic Cost Anomaly Detection” and states anomalies can be accessed via SQL functions/views in `SNOWFLAKE.LOCAL`, enabling automation (e.g., piping to Slack/PagerDuty) rather than manual UI triage. [Snowflake Well-Architected Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
- Snowflake’s ML Functions are available via SQL for time-series **Forecasting** and **Anomaly Detection** (plus Contribution Explorer), and can be operationalized with Tasks + Stored Procedures. [Snowflake ML Functions guide](https://www.snowflake.com/en/developers/guides/ml-forecasting-ad/)
- For foundational cost narratives in-app, Snowflake breaks cost into compute (virtual warehouses, serverless, cloud services), storage, and data transfer; notably, warehouses bill per-second with a **60-second minimum** per start, and cloud services compute is charged only beyond a threshold (10% of daily warehouse usage per doc). [Understanding overall cost](https://docs.snowflake.com/en/user-guide/cost-understanding-overall)

## Snowflake objects & data sources (verify in target account)
- **ACCOUNT_USAGE (history + attribution inputs)**
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (referenced as a primary source for forecasting baseline in Well-Architected doc). [Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (for driver correlation, per the same). [Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
- **SNOWFLAKE.LOCAL (programmatic anomalies)**
  - Cost anomaly SQL functions/views are available here (exact object names to confirm in a live account; doc references “SQL functions and views available within the SNOWFLAKE.LOCAL schema”). [Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
- **Budgets (control plane)**
  - Budgets + roles like `BUDGET_ADMIN` / `BUDGET_VIEWER` exist and are usable outside ACCOUNTADMIN context (verify grant paths in target account). [Snowflake blog](https://www.snowflake.com/en/blog/cost-management-interface-generally-available/)
- **ML Functions / classes**
  - `SNOWFLAKE.ML` forecasting + anomaly detection functions/classes exist (see guide + docs linked from it). [Snowflake ML Functions guide](https://www.snowflake.com/en/developers/guides/ml-forecasting-ad/)

## MVP features unlocked (PR-sized)
1) **Forecast vs Budget dashboard (account + warehouse)**: a daily table of credits consumed + a 30/60-day forecast with confidence bounds; show variance vs budget threshold bands.
2) **Programmatic anomaly ingestion → alerts**: ingest “account-level cost anomalies” from `SNOWFLAKE.LOCAL` into the app’s internal tables and route to Slack/email/webhook with owner mapping.
3) **Custom anomaly detection at lower grain** (warehouse/query-tag/team): run `SNOWFLAKE.ML.ANOMALY_DETECTION` against daily credits by dimension; emit an “incident” record with drilldown links.

## Heuristics / detection logic (v1)
- **Forecasting grain:** daily credits (or currency if available) per dimension:
  - account total
  - warehouse
  - warehouse × query_tag / cost_center_tag (preferred)
- **Simple baselines:** start with moving average + seasonality detection; upgrade to `SNOWFLAKE.ML.FORECAST` for production.
- **Anomaly thresholds:**
  - “hard” anomaly: P(credit_today > forecast_p95) OR z-score > 3
  - “soft” anomaly: forecast_p80 breach 2+ consecutive days
- **Ownership routing:** map dimension keys → owners (e.g., warehouse owner tag, or business unit tag). (This aligns with guidance that anomalies should have an owner + notifications configured.) [Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)

## Concrete artifact: SQL draft (daily credits forecast + anomaly)
> Intent: show the *minimum viable* SQL that a Native App can deploy into a customer account to produce daily forecasts and flag anomalies. Adjust object names, editions, and privileges based on target account.

```sql
-- 1) Create a daily credits table from ACCOUNT_USAGE warehouse metering
-- NOTE: confirm column names in WAREHOUSE_METERING_HISTORY in target account.
CREATE OR REPLACE TABLE FINOPS_INT.DAILY_WAREHOUSE_CREDITS AS
SELECT
  DATE_TRUNC('DAY', START_TIME) AS DAY,
  WAREHOUSE_NAME,
  SUM(CREDITS_USED) AS CREDITS_USED
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('DAY', -180, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- 2) Train a forecast model per warehouse
-- (pattern taken from Snowflake ML Functions guide: create forecast using SYSTEM$REFERENCE)
CREATE OR REPLACE VIEW FINOPS_INT.WH_CREDITS_TS AS
SELECT
  DAY AS TS,
  WAREHOUSE_NAME AS SERIES,
  CREDITS_USED AS Y
FROM FINOPS_INT.DAILY_WAREHOUSE_CREDITS;

CREATE OR REPLACE FORECAST FINOPS_INT.WH_CREDITS_FORECAST (
  INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'FINOPS_INT.WH_CREDITS_TS'),
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME => 'Y'
);

-- 3) Generate a forward forecast (horizon and method vary by syntax/version)
-- NOTE: finalize with current forecasting-class syntax in docs.
-- Example pattern (pseudo):
-- CALL FINOPS_INT.WH_CREDITS_FORECAST!FORECAST(
--   FORECASTING_PERIODS => 30,
--   SERIES_COLNAME => 'SERIES'
-- );

-- 4) Custom anomaly detection on daily credits
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION FINOPS_INT.WH_CREDITS_ANOM (
  INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'FINOPS_INT.WH_CREDITS_TS'),
  SERIES_COLNAME => 'SERIES',
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME => 'Y',
  LABEL_COLNAME => ''
);

-- Example inference:
-- CALL FINOPS_INT.WH_CREDITS_ANOM!DETECT_ANOMALIES(
--   INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'FINOPS_INT.WH_CREDITS_TS'),
--   SERIES_COLNAME => 'SERIES',
--   TIMESTAMP_COLNAME => 'TS',
--   TARGET_COLNAME => 'Y',
--   CONFIG_OBJECT => {'prediction_interval': 0.95}
-- );
```

## Security/RBAC notes
- Treat “read cost telemetry” and “configure controls (budgets/alerts)” as separate permissions:
  - Read-only analysts: can view dashboards (app UI) + app-maintained tables.
  - FinOps operators: can configure alert routing + ownership mappings.
  - Platform admins: can create/update Budgets / Resource Monitors.
- Snowflake indicates budgets can be used by roles with `BUDGET_ADMIN` / `BUDGET_VIEWER` (so Native App should integrate with those roles rather than assuming ACCOUNTADMIN). [Snowflake blog](https://www.snowflake.com/en/blog/cost-management-interface-generally-available/)

## Risks / assumptions
- **Object names / syntax drift:** ML function/class syntax (forecast/anomaly) can evolve; the artifact above needs validation against current docs for the customer’s account version.
- **Data latency:** ACCOUNT_USAGE views can have latency; forecasting/anomaly jobs may need to tolerate lag or use more real-time sources where available.
- **Currency vs credits:** some org-level datasets may provide currency-level spend; this note uses credits as the default since it’s widely available.
- **SNOWFLAKE.LOCAL anomaly surface:** We still need to confirm exact function/view names and required privileges for programmatic anomaly access in target accounts.

## Links / references
- Snowflake blog: Cost Management Interface GA (budgets + forecasting + roles) — https://www.snowflake.com/en/blog/cost-management-interface-generally-available/
- Snowflake Well-Architected: Cost Optimization (forecasting framework + programmatic anomalies + alerts) — https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- Snowflake Developer Guide: ML Functions (forecasting + anomaly detection patterns + tasks) — https://www.snowflake.com/en/developers/guides/ml-forecasting-ad/
- Snowflake Docs: Understanding overall cost (compute/storage/transfer + warehouse billing details) — https://docs.snowflake.com/en/user-guide/cost-understanding-overall
