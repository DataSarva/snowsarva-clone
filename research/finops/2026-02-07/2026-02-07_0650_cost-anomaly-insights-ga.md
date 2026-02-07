# Research: FinOps - 2026-02-07

**Time:** 06:50 UTC (Research Index: 1)
**Topic:** Snowflake Cost Anomaly Insights (GA + Non-Admin Access Rollout)
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Cost Anomaly Insights went GA on Dec 10, 2025** and is now available to non-admin users as of Feb 5, 2026 via three new application roles: `APP_USAGE_VIEWER`, `APP_USAGE_ADMIN`, and `APP_ORGANIZATION_BILLING_VIEWER`.

2. **Native algorithm uses 28-day lookback** with decomposition into trend + weekly seasonality. Requires minimum 30 days consumption history. Anomalies flagged when actual usage exceeds prediction interval (default 0.99).

3. **Anomalies computed in both credits and currency**; currency access restricted to admin users only. This creates a tiered visibility model.

4. **Granularity is daily at account/org level** — not warehouse-level or user-level. For granular detection, users must build custom ML-based anomaly detection using Snowflake Cortex `ANOMALY_DETECTION` class.

5. **New access model democratizes cost visibility** without requiring ACCOUNTADMIN. This aligns with FinOps principle of shared cost ownership across teams.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.LOCAL.ANOMALY_INSIGHTS` | Class | Snowflake built-in | Programmatic access to anomaly data |
| `ANOMALY_INSIGHTS!GET_DAILY_CONSUMPTION_ANOMALY_DATA` | Method | SNOWFLAKE.LOCAL | Returns daily consumption + is_anomaly flag |
| `SNOWFLAKE.ACCOUNT_USAGE.ANOMALIES_DAILY` | View | ACCOUNT_USAGE | Historical account-level anomalies (credits) |
| `SNOWFLAKE.ORGANIZATION_USAGE.ANOMALIES_IN_CURRENCY_DAILY` | View | ORGANIZATION_USAGE | Org-level anomalies (currency) - requires ORGADMIN |
| `SNOWFLAKE.ML.ANOMALY_DETECTION` | Class | Snowflake ML | Custom ML-based detection for granular patterns |
| `WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Source data for custom warehouse-level detection |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORGANIZATION_USAGE` = Organization-level
- `SNOWFLAKE.LOCAL` = Built-in application objects

---

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Anomaly Alerting Service for Native App**: Build automated email/Slack notifications when `GET_DAILY_CONSUMPTION_ANOMALY_DATA` returns `is_anomaly=TRUE`. Uses Snowflake Alerts + email integration.

2. **Warehouse-Level Anomaly Detection**: Implement custom `ANOMALY_DETECTION` ML model per-warehouse for granular detection beyond native daily account-level anomalies. Triggers on hourly patterns.

3. **Anomaly Investigation Dashboard**: Streamlit/Snowsight dashboard that queries anomalies, then drills into `QUERY_HISTORY` + `WAREHOUSE_METERING_HISTORY` for root cause analysis when anomalies detected.

---

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact 1: Query Native Anomaly Data

```sql
-- Account-level anomalies (requires APP_USAGE_VIEWER role minimum)
SELECT 
    date,
    account_name,
    credits_consumed,
    is_anomaly,
    expected_credits,
    lower_bound,
    upper_bound
FROM TABLE(SNOWFLAKE.LOCAL.ANOMALY_INSIGHTS!GET_DAILY_CONSUMPTION_ANOMALY_DATA(
    START_DATE => DATEADD(day, -30, CURRENT_DATE()),
    END_DATE => CURRENT_DATE(),
    ACCOUNT_NAME => CURRENT_ACCOUNT()  -- NULL for org-level
))
WHERE is_anomaly = TRUE
ORDER BY date DESC;
```

### Artifact 2: Custom Warehouse-Level Anomaly Detection

```sql
-- Step 1: Create training view for specific warehouse
CREATE OR REPLACE VIEW my_warehouse_training AS
SELECT 
    TO_TIMESTAMP_NTZ(START_TIME) AS ts,
    SUM(CREDITS_USED_COMPUTE) AS credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'PROD_ETL_WH'
  AND START_TIME BETWEEN DATEADD(day, -90, CURRENT_DATE()) 
                     AND DATEADD(day, -30, CURRENT_DATE())
GROUP BY START_TIME;

-- Step 2: Train ML model
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION wh_anomaly_model(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'my_warehouse_training'),
    TIMESTAMP_COLNAME => 'ts',
    TARGET_COLNAME => 'credits_used',
    LABEL_COLNAME => ''
);

-- Step 3: Detect anomalies on recent data
CALL wh_anomaly_model!DETECT_ANOMALIES(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'my_warehouse_test'),
    TIMESTAMP_COLNAME => 'ts',
    TARGET_COLNAME => 'credits_used',
    CONFIG_OBJECT => {'prediction_interval': 0.95}
);
```

### Artifact 3: Alert Configuration for Anomaly Detection

```sql
-- Create alert for anomaly detection (requires email integration setup)
CREATE OR REPLACE ALERT cost_anomaly_alert
WAREHOUSE = admin_wh
SCHEDULE = 'USING CRON 0 9 * * * America/Chicago'  -- Daily 9AM CST
IF (EXISTS (
    SELECT 1 FROM TABLE(SNOWFLAKE.LOCAL.ANOMALY_INSIGHTS!GET_DAILY_CONSUMPTION_ANOMALY_DATA(
        START_DATE => CURRENT_DATE() - 1,
        END_DATE => CURRENT_DATE(),
        ACCOUNT_NAME => CURRENT_ACCOUNT()
    ))
    WHERE is_anomaly = TRUE
))
THEN CALL SYSTEM$SEND_EMAIL(
    'finops_alerts_integration',
    'platform-team@company.com',
    'Snowflake Cost Anomaly Detected',
    'Daily credit consumption outside expected range. Review Cost Management > Anomalies in Snowsight.'
);
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Native anomaly detection is daily granularity only | Cannot detect intra-day spikes or hourly anomalies | Documented - requires custom ML solution |
| Requires 30 days history before first detection | New accounts cannot use anomaly detection for first month | Confirmed in docs |
| App roles may not be available in all account types | Feature access varies by edition | Test with APP_USAGE_VIEWER role grant |
| Currency conversion rates not exposed | Cost attribution in native currency requires custom logic | Verify ORGANIZATION_BILLING_VIEWER access |
| Prediction interval default (0.99) may be too strict | Too few anomalies flagged for aggressive detection | Can tune via custom ML model only |

---

## Links & Citations

1. **Snowflake Docs: Introduction to Cost Anomalies** - https://docs.snowflake.com/en/user-guide/cost-anomalies
   - Official documentation on native anomaly detection

2. **Snowflake Engineering Blog: Anomaly Insights for Non-Admins** - https://www.snowflake.com/en/engineering-blog/anomaly-insights-spending-patterns/
   - Feb 5, 2026 announcement of tiered access roles

3. **Snowflake ML Anomaly Detection** - https://docs.snowflake.com/en/user-guide/ml-functions/anomaly-detection
   - Documentation for custom Cortex ML-based detection

4. **Medium: ML-Based Alerts for Snowflake FinOps** - https://medium.com/snowflake/machine-learning-based-alerts-for-snowflake-finops-8ec640fb1cee
   - Practical implementation pattern with Tasks + Alerts

5. **Snowflake Well-Architected: Cost Optimization** - https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
   - Best practices and anomaly detection recommendations

---

## Next Steps / Follow-ups

- [ ] Test `APP_USAGE_VIEWER` role permissions in dev account
- [ ] Prototype custom warehouse-level anomaly detection vs native comparison
- [ ] Evaluate third-party tools (Select, Ternary) for gap analysis
- [ ] Design anomaly investigation drill-down UX for Native App

---

*Research completed: 2026-02-07 06:50 UTC*
