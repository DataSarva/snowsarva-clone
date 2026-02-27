# Research: FinOps - 2026-02-27

**Time:** 05:18 UTC  
**Topic:** Snowflake FinOps Cost Attribution primitives (tags, per-query attribution, budgets) → Native App design hooks  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is to use **object tags** to associate resources/users with cost centers, and **query tags** when a single application issues queries on behalf of multiple cost centers/users. (Docs) [1]
2. Within a single account, “cost by tag” in SQL is primarily composed by joining **ACCOUNT_USAGE.TAG_REFERENCES** to consumption views such as **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** (warehouse credits) and **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** (per-query attributed compute). (Docs) [1]
3. **QUERY_ATTRIBUTION_HISTORY** provides per-query warehouse compute attribution but **excludes warehouse idle time** and excludes other cost classes (storage, data transfer, cloud services, serverless features, AI token costs, etc.). (Docs) [1]
4. For compute-cost exploration, Snowflake explicitly distinguishes “credits consumed” vs “credits billed” for **cloud services**: cloud services are billed only if daily cloud services usage exceeds 10% of warehouse usage; **METERING_DAILY_HISTORY** can be used to determine billed credits. (Docs) [2]
5. ACCOUNT_USAGE views have **built-in latency** (typically ~45 minutes to a few hours; some specific views have longer), and Snowflake cautions against `SELECT *` because view schemas can change. (Docs) [3]
6. For least-privilege access to ACCOUNT_USAGE, Snowflake provides SNOWFLAKE database roles (e.g., **USAGE_VIEWER**, **GOVERNANCE_VIEWER**, **SECURITY_VIEWER**, **OBJECT_VIEWER**) that map to specific views. (Docs) [3]
7. Snowflake introduced **tag-based budgets**: budgets can monitor a tag (including via inheritance) instead of enumerating resources; when a tag scope changes, the budget’s attribution is expected to reflect within hours and backfill for the current month. (Snowflake engineering blog) [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---:|---|---|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | view | ACCOUNT_USAGE | Maps tags → objects/users; join key often `OBJECT_ID`; filter by `DOMAIN`. [1][3] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | view | ACCOUNT_USAGE | Hourly warehouse credits; can be joined to TAG_REFERENCES for warehouse-level chargeback. [1][2][3] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | view | ACCOUNT_USAGE | Per-query attributed warehouse compute credits; excludes idle time + non-warehouse costs. [1][2][3] |
| SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY | view | ACCOUNT_USAGE | Daily totals + cloud services adjustment; recommended for “billed” compute. [2][3] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | view | ORG_USAGE | Org-wide warehouse metering for an org account; useful for multi-account rollups. [1][2] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | view | ORG_USAGE | Available only in org account; enables org-wide tag references. (No org-wide QUERY_ATTRIBUTION_HISTORY.) [1] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag coverage + drift” report** for FinOps: for each `DOMAIN` (WAREHOUSE/USER/DATABASE/SCHEMA/TABLE/COMPUTE_POOL), compute tagged vs untagged counts and recent changes; use ACCOUNT_USAGE.TAG_REFERENCES + object inventory views, and surface gaps as governance tasks.
2. **Reconciled warehouse compute chargeback**: allocate warehouse monthly compute to cost centers using `QUERY_ATTRIBUTION_HISTORY` (for active compute) plus proportional distribution of warehouse idle credits using WAREHOUSE_METERING_HISTORY. (SQL artifact below) [1]
3. **Budget assist / policy hints**: recommend when to use tag-based budgets vs resource monitors based on workload profile (serverless-heavy vs warehouse-heavy), and generate the minimal set of “tag this first” actions (warehouses + compute pools + schema/database for inheritance). [4]

## Concrete Artifacts

### Artifact: SQL draft — monthly warehouse compute chargeback by `cost_center`

**Goal:** Provide a “best available” monthly compute chargeback by cost center **within a single account**, reconciling warehouse credits by distributing idle credits proportionally across cost centers.

**Inputs:**
- Users are tagged with `cost_center` via object tags (DOMAIN='USER'), **or** queries are query-tagged (QUERY_TAG) with a `COST_CENTER=...` convention.
- This draft shows user-tag-based attribution because Snowflake’s docs explicitly describe tagging users + joining TAG_REFERENCES to QUERY_ATTRIBUTION_HISTORY. (Docs) [1]

```sql
-- Monthly compute chargeback by COST_CENTER (single account)
-- Strategy:
--   1) Compute total warehouse compute credits for the month (includes idle)
--   2) Compute per-cost_center attributed query credits (excludes idle)
--   3) Distribute idle credits proportionally to the attributed credits
-- Notes:
--   - QUERY_ATTRIBUTION_HISTORY excludes non-warehouse costs (serverless/storage/etc.). [1]
--   - ACCOUNT_USAGE view latency applies; prefer explicit columns (avoid SELECT *). [3]

SET start_ts = DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE()));
SET end_ts   = DATE_TRUNC('MONTH', CURRENT_DATE());

WITH
-- 1) Warehouse bill (credits used for compute across all warehouses)
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS wh_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
    AND warehouse_id > 0
),

-- 2) Attributed query credits by user (active compute only)
user_q AS (
  SELECT
    user_name,
    SUM(credits_attributed_compute) AS attributed_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1
),

-- 3) Map user -> cost_center via tag references (DOMAIN='USER')
user_cost_center AS (
  SELECT
    tr.object_name AS user_name,
    COALESCE(tr.tag_value, 'untagged') AS cost_center
  FROM snowflake.account_usage.tag_references tr
  WHERE tr.domain = 'USER'
    AND tr.tag_name = 'COST_CENTER'
  -- Optional hardening: also filter by tag_database/tag_schema if you centralize tags
  -- AND tr.tag_database = 'COST_MANAGEMENT' AND tr.tag_schema = 'TAGS'
),

-- 4) Roll up to cost_center
cc_active AS (
  SELECT
    COALESCE(ucc.cost_center, 'untagged') AS cost_center,
    SUM(uq.attributed_credits) AS active_credits
  FROM user_q uq
  LEFT JOIN user_cost_center ucc
    ON uq.user_name = ucc.user_name
  GROUP BY 1
),

cc_totals AS (
  SELECT
    SUM(active_credits) AS sum_active
  FROM cc_active
)

SELECT
  a.cost_center,
  a.active_credits,
  /* Proportional distribution of idle credits */
  CASE
    WHEN t.sum_active = 0 THEN NULL
    ELSE (a.active_credits / t.sum_active) * w.wh_compute_credits
  END AS active_plus_idle_credits,
  w.wh_compute_credits AS month_wh_compute_credits
FROM cc_active a
CROSS JOIN cc_totals t
CROSS JOIN wh_bill w
ORDER BY active_plus_idle_credits DESC;
```

**Extensions (Native App backlog):**
- Support “application/workload” chargeback using `QUERY_TAG` (docs pattern is `ALTER SESSION SET QUERY_TAG = ...`). [1]
- Add optional “warehouse tag” fallback when warehouses are dedicated cost centers (TAG_REFERENCES join on warehouse_id/object_id). [1]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Users are consistently tagged with `COST_CENTER` or queries consistently carry `QUERY_TAG` conventions. | Chargeback buckets will have large “untagged” allocation, reducing trust in the app. | Build a tag coverage report + alert on untagged spend (MVP #1). [1] |
| ACCOUNT_USAGE latency (and 1-year retention) is acceptable for “daily/weekly FinOps” use cases. | Near-real-time dashboards may be misleading; missing latest hours of activity. | Document latencies and provide “data freshness” indicators. [3] |
| QUERY_ATTRIBUTION_HISTORY is sufficient for compute chargeback; it excludes non-warehouse costs and excludes idle time. | If customer expects all-in cost (serverless, storage, data transfer), results will not match invoice totals. | Pair with METERING_DAILY_HISTORY (billed) + feature-specific usage views; label what is/isn’t included. [1][2] |
| Org-wide per-query chargeback is feasible. | It is **not** available org-wide because no ORG_USAGE equivalent exists for QUERY_ATTRIBUTION_HISTORY. | Restrict per-query attribution to per-account views; org-wide rollups require warehouse-level aggregation. [1] |
| Budget signals can be pulled programmatically in a Native App. | If budgets are UI/notification only, app integration may be limited. | Follow-up: confirm budget object DDL + usage views/APIs (not covered in extracted sources). [4] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake Docs — Account Usage (latency, retention, roles): https://docs.snowflake.com/en/sql-reference/account-usage
4. Snowflake Engineering Blog — Tag-based budgets: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Next Steps / Follow-ups

- Verify whether **budget objects** (tag-based budgets) are queryable via a usage view / DDL / API that a Native App can read, and what privileges are needed. [4]
- Expand the artifact into a **standardized app-owned “cost attribution mart”** (daily partitions) with explicit “included cost classes” metadata.
- Add an “org-mode” design: org-wide warehouse metering by tag (ORG_USAGE.WAREHOUSE_METERING_HISTORY + ORG_USAGE.TAG_REFERENCES) for showback, and per-account deep drill for per-query attribution. [1][2]
