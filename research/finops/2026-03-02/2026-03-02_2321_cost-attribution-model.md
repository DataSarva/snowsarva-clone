# Research: FinOps - 2026-03-02

**Time:** 23:21 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended pattern for chargeback/showback is to use **object tags** (to associate resources/users to cost centers) and **query tags** (to associate individual queries when a shared app issues queries on behalf of many cost centers). [https://docs.snowflake.com/en/user-guide/cost-attributing]
2. For **within-account** cost attribution by tag, Snowflake explicitly calls out these `SNOWFLAKE.ACCOUNT_USAGE` views: `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, and `QUERY_ATTRIBUTION_HISTORY`. [https://docs.snowflake.com/en/user-guide/cost-attributing]
3. `QUERY_ATTRIBUTION_HISTORY` provides per-query compute credits attributed to query execution and **excludes warehouse idle time**; the doc also states latency can be up to **8 hours** and that short-running queries (<= ~100ms) are currently not included. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history]
4. `WAREHOUSE_METERING_HISTORY` provides hourly warehouse credits including a column for `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` and notes that **warehouse idle time is not included** in that column; Snowflake provides an example to compute idle cost as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`. [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history]
5. `USAGE_IN_CURRENCY_DAILY` in `SNOWFLAKE.ORGANIZATION_USAGE` can return **daily usage in credits and usage in currency** across an organization; its latency may be up to **72 hours**, and customers under a reseller contract may not have access. [https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily]
6. Resource monitors can be used to control and cap **warehouse** credit usage (and related cloud services), including suspending warehouses at thresholds, but they **do not** work for serverless features and AI services; Snowflake recommends using **budgets** for those. [https://docs.snowflake.com/en/user-guide/resource-monitors] [https://docs.snowflake.com/en/user-guide/budgets]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Maps tags → objects/users. Used for “by tag” attribution joins. [cost-attributing doc] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse credit usage; includes compute + cloud services credits columns; latency up to ~180 min for most columns (cloud services up to 6h). [warehouse metering doc] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query attributed compute credits + QAS credits; excludes idle time; latency up to 8h; short queries not included. [query attribution doc] |
| SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY | view | ORG_USAGE | Daily usage in currency by account/service type; latency up to 72h; not available to some reseller customers. [usage in currency daily doc] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | view | ORG_USAGE | Tag references exists org-wide *only in org account* (per cost-attributing). No org-wide query attribution equivalent. [cost-attributing doc] |
| Budgets objects + methods (e.g. `... ! GET_SPENDING_HISTORY`) | object/method | local schema (budget object) | Budgets can send notifications and trigger stored procedures; refresh tier affects budget compute overhead. [budgets docs] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag coverage & drift report**: nightly report of “untagged” warehouses/users + top spend in untagged bucket (based on `TAG_REFERENCES` + `WAREHOUSE_METERING_HISTORY`). Output to a simple table + Snowsight worksheet.
2. **Idle-time allocator**: compute “idle credits” per warehouse-hour from `WAREHOUSE_METERING_HISTORY` and allocate it proportionally to query tags / users based on `QUERY_ATTRIBUTION_HISTORY` (mirrors Snowflake’s own SQL examples).
3. **Org-level spend reconciler**: a lightweight pipeline that reads `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` to produce “actual billed-ish” daily currency spend by account/service type (with explicit 72h latency) and reconciles it to in-account credit-based reports.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Daily compute credits by `cost_center` tag + idle allocation (account scope)

Goal: produce a daily table by cost center that (a) attributes query execution credits directly from `QUERY_ATTRIBUTION_HISTORY` and (b) allocates warehouse idle credits proportionally by cost center.

Notes:
- This follows Snowflake’s documented approach (tags + attribution views), and mirrors the “including idle time” pattern described in examples. [https://docs.snowflake.com/en/user-guide/cost-attributing]
- This is **account-only**; there is no org-wide `QUERY_ATTRIBUTION_HISTORY`. [https://docs.snowflake.com/en/user-guide/cost-attributing]

```sql
-- Parameters
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());

-- 1) Query execution credits by cost_center (via tagged users or via QUERY_TAG)
-- Pick ONE primary mapping strategy:
--   A) Tag USER objects with cost_center (recommended for shared warehouses)
--   B) Use QUERY_TAG (recommended for shared applications)

WITH
-- A) user tag mapping: USER -> cost_center
user_cost_center AS (
  SELECT
      object_name              AS user_name,
      COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'USER'
    AND tag_name = 'COST_CENTER'
),

-- Raw query attribution (execution-only; excludes idle)
q AS (
  SELECT
      DATE_TRUNC('day', start_time) AS usage_date,
      warehouse_id,
      warehouse_name,
      user_name,
      NULLIF(query_tag, '')         AS query_tag,
      credits_attributed_compute,
      COALESCE(credits_used_query_acceleration, 0) AS credits_qas
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
),

-- Execution credits by cost center (strategy A: user tag)
exec_by_cc AS (
  SELECT
      q.usage_date,
      COALESCE(u.cost_center, 'untagged') AS cost_center,
      SUM(q.credits_attributed_compute)    AS exec_credits,
      SUM(q.credits_qas)                   AS qas_credits
  FROM q
  LEFT JOIN user_cost_center u
    ON q.user_name = u.user_name
  GROUP BY 1, 2
),

-- 2) Warehouse idle credits per day
wh_idle_by_day AS (
  SELECT
      DATE_TRUNC('day', start_time) AS usage_date,
      warehouse_id,
      warehouse_name,
      -- Snowflake docs show idle cost = credits_used_compute - credits_attributed_compute_queries
      SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND warehouse_id > 0
  GROUP BY 1, 2, 3
),

-- 3) Allocate idle credits proportionally to execution credits by cost_center
-- Compute each cost_center's share of execution credits per day.
exec_total_by_day AS (
  SELECT usage_date, SUM(exec_credits) AS exec_credits_total
  FROM exec_by_cc
  GROUP BY 1
),

idle_allocated AS (
  SELECT
      e.usage_date,
      e.cost_center,
      -- allocate ALL idle across cost centers by share of execution credits
      SUM(w.idle_credits) * (e.exec_credits / NULLIF(t.exec_credits_total, 0)) AS idle_credits_alloc
  FROM exec_by_cc e
  JOIN exec_total_by_day t
    ON e.usage_date = t.usage_date
  JOIN wh_idle_by_day w
    ON e.usage_date = w.usage_date
  GROUP BY 1, 2, e.exec_credits, t.exec_credits_total
)

SELECT
    e.usage_date,
    e.cost_center,
    e.exec_credits,
    e.qas_credits,
    COALESCE(i.idle_credits_alloc, 0) AS idle_credits_alloc,
    e.exec_credits + COALESCE(i.idle_credits_alloc, 0) AS total_compute_credits_alloc
FROM exec_by_cc e
LEFT JOIN idle_allocated i
  ON e.usage_date = i.usage_date
 AND e.cost_center = i.cost_center
ORDER BY 1 DESC, 5 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` does not include very short queries (<= ~100ms) and has up to ~8h latency. | Under-count for workloads dominated by very short queries; dashboards appear to “lag”. | Validate by comparing query counts vs `QUERY_HISTORY` and measuring “missing” proportion for top warehouses. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history] |
| Allocation of idle credits “proportionally to execution credits” is a policy choice (not the only valid one). | Chargeback disputes (“why am I paying idle?”) | Offer multiple policies: allocate by exec credits, by warehouse ownership tags, or keep idle as “shared overhead”. Document policy per tenant. |
| Org-level currency views (`USAGE_IN_CURRENCY_DAILY`) can change until month close; latency up to 72h; reseller contracts may not have access. | Reconciliation drift; customers may not be able to use org-wide currency features. | Detect availability early; support fallback to credit-only reporting. [https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily] |
| Resource monitors don’t cover serverless/AI services; budgets do, but budgets have their own cost tradeoffs (refresh tier). | Incomplete guardrails if only resource monitors are used. | Implement guardrail UX: recommend resource monitor for warehouses + budget for serverless/AI. [https://docs.snowflake.com/en/user-guide/resource-monitors] [https://docs.snowflake.com/en/user-guide/budgets] |

## Links & Citations

1. Attributing cost (tags + within-account and org patterns; views to query): https://docs.snowflake.com/en/user-guide/cost-attributing
2. QUERY_ATTRIBUTION_HISTORY view (per-query credits; excludes idle; latency; short query limitation): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. WAREHOUSE_METERING_HISTORY view (hourly credits; idle vs attributed compute queries; latency notes): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. USAGE_IN_CURRENCY_DAILY view (org-wide daily usage in currency; latency; limitations): https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
5. Working with resource monitors (warehouse-only cost controls; suspend actions; limitations): https://docs.snowflake.com/en/user-guide/resource-monitors
6. Monitor credit usage with budgets (budgets for serverless + notifications + actions; supported services): https://docs.snowflake.com/en/user-guide/budgets

## Next Steps / Follow-ups

- Turn the SQL draft into a **materialized daily fact table** (`FINOPS.COST_ATTRIBUTION_DAILY`) + incremental task.
- Add a second attribution strategy using `QUERY_TAG` (instead of user tags) for shared applications.
- Pull org-level currency daily spend into the same model when available; keep a “data freshness” field due to 72h latency.
