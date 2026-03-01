# Research: FinOps - 2026-03-01

**Time:** 15:04 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake recommends using **object tags** (e.g., tag warehouses/users with a `cost_center`) and/or **query tags** (e.g., set `QUERY_TAG`) as the foundation for showback/chargeback cost attribution. (Docs: Attributing cost) 
2. For warehouse compute costs, Snowflake’s **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY** provides **hourly credit usage** by warehouse and includes a column for credits attributed to queries; it also explicitly notes that **warehouse idle time is not included** in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. (Docs: WAREHOUSE_METERING_HISTORY view)
3. Snowflake’s **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** provides per-query compute credits, but its per-query cost **does not include warehouse idle time** (idle time can only be measured at the warehouse level). (Docs: Attributing cost)
4. Many cost/usage views report **credits consumed** (including cloud services consumption); however, **cloud services is only billed** when daily cloud services consumption exceeds **10%** of daily warehouse usage. To determine credits actually billed for compute costs (including the cloud services adjustment), Snowflake directs you to query **METERING_DAILY_HISTORY**. (Docs: Exploring compute cost)
5. For organization-wide rollups, there are ORG_USAGE equivalents for many metering views, but **QUERY_ATTRIBUTION_HISTORY is account-only** (no organization-wide equivalent). (Docs: Attributing cost)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by warehouse; includes `CREDITS_USED_*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; latency up to ~3h (cloud services column up to ~6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits; docs state it excludes warehouse idle time. No org-wide equivalent. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Maps tagged objects/users to tag name/value; joinable to warehouse metering via `object_id` (warehouse) or `object_name` (user). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily credits with cloud services adjustment; use to compute “actually billed” credits per day. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Org-wide warehouse metering; use with ORG `TAG_REFERENCES` (available only in org account) for multi-account showback. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost attribution rollup by object tags (warehouses) + query tags**: ship a default “chargeback” report that produces daily/monthly credits by `cost_center` with “untagged” surfaced explicitly.
2. **Idle cost & waste detector per warehouse**: compute `idle_cost = credits_used_compute - credits_attributed_compute_queries` and rank warehouses by idle ratio/credits.
3. **Billed vs consumed reconciliation panel**: show “credits consumed” (hourly metering) vs “credits billed” (daily metering with cloud services adjustment) to prevent finance/reporting drift.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: monthly warehouse chargeback by `cost_center` tag (warehouses)

This is the canonical join pattern Snowflake documents for attributing a department’s credits when warehouses are dedicated per department.

```sql
-- Purpose:
--   Monthly compute credits by warehouse cost_center tag (dedicated warehouses case)
-- Source of truth:
--   WAREHOUSE_METERING_HISTORY (ACCOUNT_USAGE)
-- Notes:
--   Surfaces untagged explicitly.

SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS cost_center,
  SUM(wmh.credits_used_compute)      AS compute_credits
FROM snowflake.account_usage.warehouse_metering_history AS wmh
LEFT JOIN snowflake.account_usage.tag_references AS tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
 AND tr.tag_name = 'COST_CENTER'  -- adjust to your tagging convention
WHERE wmh.start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
  AND wmh.start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY compute_credits DESC;
```

### SQL draft: idle cost per warehouse (last N days)

Based on the documented definition that idle time is excluded from `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`.

```sql
-- Purpose:
--   Identify warehouses burning credits while idle (not suspended).
-- Definition (per docs):
--   idle_cost = credits_used_compute - credits_attributed_compute_queries

SET days_back = 10;

SELECT
  warehouse_name,
  SUM(credits_used_compute)                     AS compute_credits,
  SUM(credits_attributed_compute_queries)       AS attributed_query_credits,
  SUM(credits_used_compute) -
  SUM(credits_attributed_compute_queries)       AS idle_credits,
  IFF(SUM(credits_used_compute) = 0,
      NULL,
      (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries))
      / SUM(credits_used_compute))              AS idle_ratio
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -$days_back, CURRENT_DATE)
  AND end_time   <  CURRENT_DATE
  AND warehouse_id > 0 -- skip pseudo VWs
GROUP BY 1
ORDER BY idle_credits DESC;
```

### Pseudocode: “idle cost allocation” strategy for query-tag showback

If Akhil wants chargeback by `QUERY_TAG` (apps) and also wants idle time included, Snowflake’s docs show a proportional distribution approach: scale each tag’s attributed credits up to match total warehouse compute credits.

```text
Inputs:
  W = total compute credits from WAREHOUSE_METERING_HISTORY over period
  T[tag] = sum(credits_attributed_compute) from QUERY_ATTRIBUTION_HISTORY by query_tag over period

Compute:
  total_attributed = sum_over_tag(T[tag])
  for each tag:
    attributed_including_idle[tag] = (T[tag] / total_attributed) * W

Outputs:
  attributed_including_idle[tag]
  plus an explicit 'untagged' bucket via COALESCE(NULLIF(query_tag,''),'untagged')
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES` join keys and tag naming conventions differ by org (case, database/schema, allowed values). | Wrong attribution buckets; “untagged” may be inflated. | Validate tag standards; add a tag dictionary + unit tests for joins. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time by design. Any “true billed per query” requires an allocation strategy. | Per-query or per-tag costs may not reconcile to billed totals without explicit allocation. | Implement explicit “include_idle_time” mode and reconcile to `WAREHOUSE_METERING_HISTORY` totals. |
| Billing reconciliation is tricky because cloud services billing is adjusted daily (10% rule). | Stakeholder distrust if dashboards don’t match invoices. | Use `METERING_DAILY_HISTORY` for billed credit totals; document the difference between consumed vs billed. |
| Data latency (ACCOUNT_USAGE up to hours; reader account up to 24h). | Near-real-time dashboards may appear “wrong” if not labeled. | UI should show freshness + last_loaded timestamps; incremental backfill. |

## Links & Citations

1. Snowflake docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs — Exploring compute cost: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. Snowflake docs — WAREHOUSE_METERING_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Pull and summarize Snowflake docs for `QUERY_ATTRIBUTION_HISTORY` specifics (filters/limits/latency, e.g., exclusions for short queries) and incorporate into the app’s attribution model.
- Draft a small internal schema for the Native App: `MC_FINOPS.ATTRIBUTION_DAILY` (date, attribution_type, key, credits_consumed, credits_billed_est, freshness_ts) with tests.
- Decide product UX: show both (a) “raw attributed credits” (excluding idle) and (b) “allocated” (including idle) with explainers.
