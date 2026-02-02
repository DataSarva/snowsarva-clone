# FinOps Research Note — Usage & cost metrics foundation for FinOps Native App (ACCOUNT_USAGE/ORG_USAGE + reconciliation)

- **When (UTC):** 2026-02-02 11:23
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs a *reliable* “source of truth” for cost + usage, with known latency/retention semantics and clear RBAC expectations. This note focuses on the SNOWFLAKE database schemas (ACCOUNT_USAGE + ORGANIZATION_USAGE) and implications for app design (data freshness, reconciliation, and monetization hooks).

## Accurate takeaways
- Snowflake’s **SNOWFLAKE** database is the primary foundation for cost visibility; the Well-Architected Framework explicitly calls out **ACCOUNT_USAGE** (granular/account) and **ORGANIZATION_USAGE** (consolidated/org-wide) for historical consumption insights.  
  Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- **ACCOUNT_USAGE** views have **natural latency** (often ~2 hours; varies ~45 min to 3 hours depending on view). Information Schema equivalents have *no* latency, but typically shorter retention and different semantics (and may omit dropped objects).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage
- When reconciling cost views between **ACCOUNT_USAGE** and **ORGANIZATION_USAGE**, Snowflake documentation warns you must **set session timezone to UTC** (e.g., for WAREHOUSE_METERING_HISTORY reconciliation).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage
- For a paid marketplace version of the FinOps app, Snowflake Native App Framework supports **Custom Event Billing**, but with constraints: billable events must be emitted via supported system functions inside stored procedures; Snowflake does *not* support arbitrary base charge computation via UDF outputs or telemetry/event-table calculations.  
  Source: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

## Snowflake objects & data sources (verify in target account)
- **SNOWFLAKE.ACCOUNT_USAGE** (account-scoped historical usage + metadata)
  - Example cost/usage-relevant views explicitly referenced by Snowflake WAF:  
    - `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly warehouse credits)  
    - `ACCOUNT_USAGE.QUERY_HISTORY` (query metrics, warehouses)  
    - `ACCOUNT_USAGE.TABLE_STORAGE_METRICS`, `ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY`  
    - `ACCOUNT_USAGE.DATA_TRANSFER_HISTORY`  
    Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
  - Semantics to design around:
    - Latency (commonly ~2h, some 45m–3h)  
      Source: https://docs.snowflake.com/en/sql-reference/account-usage
    - Longer historical retention vs Information Schema; includes dropped objects (per doc overview)  
      Source: https://docs.snowflake.com/en/sql-reference/account-usage
- **SNOWFLAKE.ORGANIZATION_USAGE** (org-wide consolidated usage)  
  - WAF calls out org-wide sources like `ORGANIZATION_USAGE.METERING_DAILY_HISTORY`, `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`, `ORGANIZATION_USAGE.RATE_SHEET_DAILY`.  
  Source: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## MVP features unlocked (PR-sized)
1) **“Data freshness + reconciliation banner”** in-app: display “last loaded timestamp” per upstream view, and warn when reconciling ACCOUNT_USAGE vs ORG_USAGE without UTC timezone.
2) **Org-wide spend vs account drilldown**: surface daily spend in currency (ORG_USAGE) with drilldowns to warehouse/query drivers (ACCOUNT_USAGE).
3) **Monetization-ready usage metering**: for a paid edition, wrap “premium analysis” stored procedures with Custom Event Billing emission (explicitly supported path).

## Heuristics / detection logic (v1)
- **Compute cost concentration**: identify top-N warehouses by credits/day and week-over-week deltas using `WAREHOUSE_METERING_HISTORY`.
- **Workload efficiency proxy (v1)**: approximate “useful compute” vs “waste” by joining hourly warehouse credits to query execution time (limitations below).
- **Freshness guardrails**: enforce minimum staleness thresholds (e.g., do not issue “today” conclusions until ACCOUNT_USAGE latency window passes).

## Concrete artifact — SQL draft: daily warehouse cost + query utilization proxy
Goal: produce a daily summary per warehouse, with a crude “query utilization ratio” (query seconds during metered hours / total hour seconds). This is **not perfect** (multi-cluster, concurrency, spilling, etc.), but works as a first-order signal.

```sql
-- NOTE: ACCOUNT_USAGE latencies apply. For reconciliation with ORGANIZATION_USAGE,
-- Snowflake docs recommend setting timezone to UTC.
ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_credits AS (
  SELECT
    DATE_TRUNC('DAY', START_TIME) AS usage_day,
    WAREHOUSE_ID,
    WAREHOUSE_NAME,
    SUM(CREDITS_USED) AS credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
),
q AS (
  SELECT
    DATE_TRUNC('DAY', START_TIME) AS usage_day,
    WAREHOUSE_ID,
    SUM(EXECUTION_TIME) / 1000.0 AS query_exec_seconds
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
    AND WAREHOUSE_ID IS NOT NULL
    AND EXECUTION_STATUS = 'SUCCESS'
  GROUP BY 1,2
),
sec_per_day AS (
  SELECT 86400.0 AS seconds_in_day
)
SELECT
  w.usage_day,
  w.warehouse_name,
  w.credits_used,
  COALESCE(q.query_exec_seconds, 0) AS query_exec_seconds,
  LEAST(1.0, COALESCE(q.query_exec_seconds, 0) / s.seconds_in_day) AS query_utilization_ratio_v1
FROM wh_credits w
LEFT JOIN q
  ON q.usage_day = w.usage_day
 AND q.warehouse_id = w.warehouse_id
CROSS JOIN sec_per_day s
ORDER BY 1 DESC, 3 DESC;
```

Where this helps the Native App:
- drives a simple “**Top waste candidates**” list: high credits_used + low query_utilization_ratio_v1.
- provides an explainable metric that can later be refined with more granular measures (queue time, spills, idle, scaling policy).

## Security/RBAC notes
- Many ACCOUNT_USAGE views require elevated privileges; docs mention using **ACCOUNTADMIN** or a role granted **IMPORTED PRIVILEGES** on SNOWFLAKE database for example queries. (Exact minimal RBAC needs should be validated per targeted views.)  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage
- If the app relies on org-wide views (ORGANIZATION_USAGE), expect additional governance: org admin roles + multi-account access patterns (may impact what a Native App can assume by default).

## Risks / assumptions
- **Utilization metric is approximate**: query execution time is not the same as warehouse “active compute”; concurrency and parallel query execution can exceed wall-clock time; multi-cluster warehouses complicate inference.
- **Latency impacts “real-time” UX**: ACCOUNT_USAGE often lags; the app should treat it as near-real-time at best, not real-time.
- **Native App billing constraints**: Custom Event Billing can’t be computed from arbitrary telemetry tables/UDF outputs; it must be emitted via supported system functions in stored procedures (design premium features accordingly).

## Links / references
- Snowflake Well-Architected Framework — Cost Optimization & FinOps: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- Snowflake Documentation — Account Usage (SNOWFLAKE.ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage
- Snowflake Documentation — Native Apps Custom Event Billing: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing
