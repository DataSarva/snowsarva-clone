# Research: FinOps - 2026-03-02

**Time:** 14:41 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended approach for chargeback/showback is: **object tags** to associate resources/users with cost centers, and **query tags** to associate individual queries with cost centers when an application runs queries on behalf of multiple departments. [1]
2. Cost attribution in SQL within a single account relies on joining **ACCOUNT_USAGE.TAG_REFERENCES** to usage views like **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** (warehouse credits) and **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** (per-query compute credits). [1]
3. **QUERY_ATTRIBUTION_HISTORY** provides per-query compute credits for warehouse-executed queries; it **excludes warehouse idle time** and excludes other credit categories (storage, cloud services, serverless, etc.). It also omits very short queries (≈<=100ms) from attribution. Latency can be **up to ~8 hours**. [3]
4. **WAREHOUSE_METERING_HISTORY** includes hourly warehouse credit usage and exposes both **CREDITS_USED_COMPUTE** and **CREDITS_ATTRIBUTED_COMPUTE_QUERIES**; the difference is a straightforward way to estimate **idle-time cost** at the warehouse level. ACCOUNT_USAGE latency is **~3 hours** (and up to 6 hours for cloud services). [4]
5. Snowflake **Budgets** monitor compute credit usage on a monthly interval (UTC month boundaries). Budgets can notify via email, cloud queues (SNS/Event Grid/PubSub), or webhooks. Custom budgets can group supported objects and can be created such that **tag-added resources are backfilled for the month**, while individually-added resources are not. [2]
6. Budgets have a refresh interval (default up to ~6.5h). “Low latency” budgets can refresh hourly, but increase the compute cost of the budget by a factor of ~12 (per docs example). [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | View | ACCOUNT_USAGE | Maps tags to Snowflake objects/users; join point for showback/chargeback. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Hourly credits per warehouse; includes compute + cloud services; can estimate idle cost via `credits_used_compute - credits_attributed_compute_queries`. [1][4] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query attributed compute credits (warehouse compute only), excludes idle time; latency up to ~8h; short queries omitted. [1][3] |
| SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY | View | ORG_USAGE | Org-wide warehouse metering; usable for “resources not shared” scenarios (warehouse-tagged). [1] |
| SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES | View | ORG_USAGE | Only available in the organization account; needed for org-wide tagging joins. [1] |
| Snowflake Budgets (SNOWFLAKE.CORE.BUDGET class + roles/privileges) | Feature/API | N/A | Budget notifications + optional stored-procedure actions; monthly windows in UTC. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag Coverage & Untagged Spend” report (account + org)**
   - Daily/weekly rollups of credits by `cost_center` tag, plus explicit “untagged” bucket for both warehouses and queries.
   - Directly uses TAG_REFERENCES + WAREHOUSE_METERING_HISTORY + QUERY_ATTRIBUTION_HISTORY patterns shown in docs. [1]
2. **Idle-cost detector per warehouse (actionable FinOps finding)**
   - Compute `idle_cost = credits_used_compute - credits_attributed_compute_queries` per warehouse per day, then rank top offenders.
   - Output recommended config checks (auto-suspend, right-sizing), but keep the calculation purely factual. [4]
3. **Budget-aware alerting surfaces inside the Native App**
   - If customers already use Budgets, the app can mirror budget state, explain the refresh/latency characteristics, and attach “what changed” breakdowns (by tag/warehouse/query tag).
   - Focus on the “backfill caveat” for custom budgets (tag-based grouping vs individually-added objects). [2]

## Concrete Artifacts

### Cost Attribution Fact Table (Daily) + Core Queries

Goal: a durable, app-friendly daily fact table that supports:
- warehouse chargeback by **object tag** (warehouse tagged)
- compute chargeback by **query tag** (workload attribution)
- user/org accountability via user tags (where available)
- explicit “idle cost” surfacing as first-class metric

```sql
-- Artifact: daily fact build (single-account).
-- Assumptions:
--   - COST_MANAGEMENT.TAGS.COST_CENTER tag exists and is applied to warehouses and/or users.
--   - Run under role with USAGE_VIEWER or equivalent access to ACCOUNT_USAGE.
--   - This is a *draft*; adjust tag db/schema/name to your environment.

CREATE OR REPLACE TABLE FINOPS.FACT_DAILY_COST_ATTRIBUTION (
  usage_date DATE,
  attribution_type STRING,                 -- 'WAREHOUSE_TAG' | 'QUERY_TAG' | 'USER_TAG'
  attribution_key STRING,                  -- e.g. cost_center tag value OR query_tag string
  warehouse_name STRING,
  credits_compute NUMBER(38,9),
  credits_qas NUMBER(38,9),
  credits_idle_estimated NUMBER(38,9),
  credits_total_estimated NUMBER(38,9),
  source_note STRING,
  updated_at TIMESTAMP_LTZ
);

-- 1) Warehouse compute credits by warehouse tag (resource not shared scenario)
INSERT INTO FINOPS.FACT_DAILY_COST_ATTRIBUTION
WITH wmh AS (
  SELECT
    start_time::DATE AS usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS credits_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
    AND end_time < CURRENT_DATE()
  GROUP BY 1,2,3
), wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_name ILIKE 'COST_CENTER'
)
SELECT
  wmh.usage_date,
  'WAREHOUSE_TAG' AS attribution_type,
  COALESCE(wh_tags.cost_center, 'untagged') AS attribution_key,
  wmh.warehouse_name,
  wmh.credits_compute AS credits_compute,
  /* QAS not in WAREHOUSE_METERING_HISTORY; keep null for this slice */
  NULL AS credits_qas,
  (wmh.credits_compute - wmh.credits_attributed_queries) AS credits_idle_estimated,
  wmh.credits_compute AS credits_total_estimated,
  'ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY joined to TAG_REFERENCES(domain=WAREHOUSE)' AS source_note,
  CURRENT_TIMESTAMP() AS updated_at
FROM wmh
LEFT JOIN wh_tags
  ON wmh.warehouse_id = wh_tags.warehouse_id;

-- 2) Query compute credits by query_tag (application/workload attribution; excludes idle time by definition)
INSERT INTO FINOPS.FACT_DAILY_COST_ATTRIBUTION
SELECT
  start_time::DATE AS usage_date,
  'QUERY_TAG' AS attribution_type,
  COALESCE(NULLIF(query_tag,''), 'untagged') AS attribution_key,
  warehouse_name,
  SUM(credits_attributed_compute) AS credits_compute,
  SUM(credits_used_query_acceleration) AS credits_qas,
  NULL AS credits_idle_estimated,
  SUM(credits_attributed_compute) + SUM(credits_used_query_acceleration) AS credits_total_estimated,
  'ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (per-query; excludes idle time)' AS source_note,
  CURRENT_TIMESTAMP() AS updated_at
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY 1,2,3,4;
```

Why this artifact is useful for a Native App:
- It collapses multiple “raw telemetry” views (wmh/qah/tag refs) into a stable contract.
- It makes “idle cost” a metric the UI can display and alert on (rather than hiding it in reconciliation logic).
- It keeps attribution slices separate (warehouse tag vs query tag) so the app can explain when they are valid.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Query attribution excludes idle time by design. Treating query-tag rollups as “total warehouse spend” will undercount unless you explicitly redistribute idle costs. | Misleading chargeback numbers if users expect totals to reconcile to warehouse credits. | Document the distinction; optionally add an “idle redistribution policy” module in the app. [1][3][4] |
| QUERY_ATTRIBUTION_HISTORY omits very short queries (≈<=100ms). | Under-attribution for workloads dominated by tiny queries; can bias cost accounting. | Compare to QUERY_HISTORY counts and flag discrepancy. [3] |
| View latencies (hours) mean dashboards/alerts will be delayed. | Real-time monitoring expectations will not be met; budgets also refresh on interval. | Surface “data freshness” explicitly in UI. [2][3][4] |
| Custom budgets backfill only for tag-added objects, not individually added resources. | First-month forecast/alerting can be inaccurate, confusing customers. | Add UX copy + detection of “budget created mid-month” if accessible. [2] |
| ORG_USAGE TAG_REFERENCES availability is limited to the org account; QUERY_ATTRIBUTION_HISTORY has no org-wide equivalent. | Native App features may need to differentiate “org rollups” vs “account drilldown”. | Confirm customer deployment target: org account vs individual account(s). [1] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Monitor credit usage with budgets: https://docs.snowflake.com/en/user-guide/budgets
3. Snowflake Docs — QUERY_ATTRIBUTION_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. Snowflake Docs — WAREHOUSE_METERING_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Extend the fact-table draft with an explicit **idle redistribution policy** (e.g., proportional to attributed compute by tag/user) and make it configurable.
- Research whether Budgets provide any programmatic “current forecast/spend” endpoints accessible from a Native App (and what privileges are required), vs needing customers to push budget state via webhook into the app.
- Add an “org vs account capability matrix” to the app docs (what is possible with ORG_USAGE vs requires per-account deployment). [1]
