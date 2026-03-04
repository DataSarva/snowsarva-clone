# Research: FinOps - 2026-03-04

**Time:** 16:24 UTC  
**Topic:** Snowflake FinOps Cost Attribution Foundation (tags + query attribution + idle reconciliation)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: **object tags** to associate resources/users to cost centers, plus **query tags** to attribute per-query usage when an application issues queries on behalf of multiple cost centers. (Snowflake docs)  
2. Within a single account, Snowflake documents cost attribution using **ACCOUNT_USAGE.TAG_REFERENCES**, **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY**, and **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY**. (Snowflake docs)  
3. **QUERY_ATTRIBUTION_HISTORY** exposes per-query compute credits (**CREDITS_ATTRIBUTED_COMPUTE**) but **explicitly excludes warehouse idle time** and excludes very short-running queries (≈ <=100ms). Latency to populate can be up to ~8 hours. (Snowflake docs)  
4. For **organization-wide** reporting, Snowflake provides **ORGANIZATION_USAGE** analogs for many metering views, but there is **no org-wide equivalent** of **QUERY_ATTRIBUTION_HISTORY**; query-level attribution is account-scoped. (Snowflake docs)  
5. Snowflake’s **cloud services credits are not always billed**; billing applies only if daily cloud services consumption exceeds **10%** of daily warehouse usage. For “what was actually billed,” Snowflake points to **METERING_DAILY_HISTORY**. (Snowflake docs)
6. Third-party practitioners report that query attribution can appear surprising for short-query workloads and recommend validating against **WAREHOUSE_METERING_HISTORY** and, when needed, building an explicit idle-time attribution model using warehouse suspend events. (Greybeam)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Maps tags → objects (WAREHOUSE/USER/etc). Used to join cost to ownership (showback/chargeback). |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse credits; source-of-truth for warehouse metered credits in many analyses. |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query attributed credits (excludes idle time; excludes very short queries; up to ~8h latency). |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | view | ACCOUNT_USAGE | Daily compute credits; used to determine whether cloud services usage was billed (10% rule). |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | view | ORG_USAGE | Cross-account warehouse metering (org account context). Query-level attribution not available org-wide. |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | view | ORG_USAGE | Converts credits consumed to currency using daily credit price (org currency). |
| SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY | view | ACCOUNT_USAGE | Daily credit usage for Snowflake Native Apps (relevant for “Native App cost footprint” reporting). |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY | view | ACCOUNT_USAGE | Can provide suspend/consistent events; can be used for explicit idle windows. (Use cautiously; validate.) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag coverage & “untagged spend” dashboard**: show (a) percent of metered warehouse credits linked to a cost_center tag (by warehouse tag), and (b) percent of query-attributed credits with empty query_tag (by QUERY_ATTRIBUTION_HISTORY). This directly operationalizes “tag hygiene.”
2. **Idle-time reconciliation model**: provide a “two numbers” view per period: (a) query-attributed credits (ex-idle) from QUERY_ATTRIBUTION_HISTORY and (b) metered credits from WAREHOUSE_METERING_HISTORY, plus delta = “idle/unattributed.” Then optionally allocate that delta to cost centers proportional to usage.
3. **Native App footprint reporting**: surface APPLICATION_DAILY_USAGE_HISTORY alongside other compute categories so admins can see spend attributable to installed Native Apps.

## Concrete Artifacts

### Artifact: SQL draft — attribute warehouse credits to QUERY_TAG (including idle-time allocation)

Goal: monthly cost by query_tag where idle credits (difference between metered warehouse credits and sum of per-query attributed credits) are allocated back to tags proportionally.

Notes:
- This intentionally uses metering from WAREHOUSE_METERING_HISTORY and per-query credits from QUERY_ATTRIBUTION_HISTORY.
- This is **account-scoped** (ORG-wide query attribution isn’t available).
- This is a *showback model*; it is not Snowflake billing.

```sql
-- COST ATTRIBUTION BY QUERY_TAG, INCLUDING IDLE (monthly)
-- Sources: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, QUERY_ATTRIBUTION_HISTORY
-- Caveats: QUERY_ATTRIBUTION_HISTORY excludes idle and very short queries; has latency.

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD('MONTH', -1, CURRENT_DATE())) AS month_start,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS month_end
),

-- 1) Total metered warehouse credits for the period
metered AS (
  SELECT
    SUM(credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= (SELECT month_start FROM params)
    AND start_time <  (SELECT month_end   FROM params)
    AND warehouse_id > 0  -- avoid pseudo-warehouses
),

-- 2) Query-attributed credits grouped by tag (excluding idle by definition)
q_tag AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS q_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= (SELECT month_start FROM params)
    AND start_time <  (SELECT month_end   FROM params)
  GROUP BY 1
),

q_total AS (
  SELECT SUM(q_credits) AS total_q_credits FROM q_tag
),

-- 3) Idle/unattributed delta (this includes true idle plus anything not represented in QUERY_ATTRIBUTION_HISTORY)
recon AS (
  SELECT
    m.metered_compute_credits,
    qt.total_q_credits,
    GREATEST(m.metered_compute_credits - qt.total_q_credits, 0) AS idle_or_unattributed_credits
  FROM metered m CROSS JOIN q_total qt
)

SELECT
  q.query_tag,
  q.q_credits AS query_attributed_credits_ex_idle,
  -- Allocate the delta proportionally to query-tag usage
  CASE
    WHEN (SELECT total_q_credits FROM recon) = 0 THEN 0
    ELSE (q.q_credits / (SELECT total_q_credits FROM recon))
         * (SELECT idle_or_unattributed_credits FROM recon)
  END AS allocated_idle_credits,
  q.q_credits
  + CASE
      WHEN (SELECT total_q_credits FROM recon) = 0 THEN 0
      ELSE (q.q_credits / (SELECT total_q_credits FROM recon))
           * (SELECT idle_or_unattributed_credits FROM recon)
    END AS total_credits_including_allocated_idle
FROM q_tag q
ORDER BY total_credits_including_allocated_idle DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| QUERY_ATTRIBUTION_HISTORY excludes idle time and very short queries | “Untagged/idle” delta can look large; small-query workloads may undercount | Reconcile vs WAREHOUSE_METERING_HISTORY; report both numbers and the delta explicitly. |
| Attribution is account-scoped; org-wide query attribution isn’t available | Native App can’t do single-query org-wide cost attribution solely from ORG_USAGE | Provide org-wide warehouse metering rollups; for query-level, do per-account drilldowns. |
| Cloud services credits may not be billed due to 10% rule | Converting credits → currency can be misleading if using raw consumed credits | Use METERING_DAILY_HISTORY and/or billing-focused views where appropriate (per Snowflake guidance). |
| WAREHOUSE_EVENTS_HISTORY reliability for suspend timestamps varies | Idle-window modeling could be wrong | If implementing event-based idle allocation, validate with small controlled experiments and compare to recon deltas. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Decide which “idle model” we want as MVP:
  - (A) Simple delta allocation (fast, transparent, no events), or
  - (B) Event-driven idle windows using WAREHOUSE_EVENTS_HISTORY (more precise, more complexity).
- Add a separate pass for **serverless feature spend** (SEARCH_OPTIMIZATION_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, PIPE_USAGE_HISTORY, etc.) from the exploring-compute-cost view list.
- Evaluate how to present **Native App footprint**: APPLICATION_DAILY_USAGE_HISTORY and/or any org-wide analogs.
