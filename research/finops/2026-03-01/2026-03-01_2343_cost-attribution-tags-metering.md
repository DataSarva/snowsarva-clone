# Research: FinOps - 2026-03-01

**Time:** 2343 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Resource monitors only work for warehouses** (user-managed virtual warehouses). They **cannot** track spending for **serverless features and AI services**; Snowflake recommends using a **budget** for those instead. Resource monitors can trigger actions (notify / suspend / suspend immediately) when thresholds are met. 
   - Source: Snowflake docs on resource monitors.

2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credit usage** per warehouse (or all warehouses) for up to **365 days**, with `CREDITS_USED` as the sum of compute + cloud services credits. View latency can be up to **180 minutes** (and `CREDITS_USED_CLOUD_SERVICES` up to **6 hours**). 
   - Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`.

3. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` identifies **direct** object↔tag associations, and explicitly **does not include tag inheritance**. It can be used to group objects (including **warehouses**) by cost-center/project tags for attribution reporting.
   - Source: Snowflake docs for `TAG_REFERENCES` view + object tagging intro.

4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `WAREHOUSE_NAME` and `QUERY_TAG` (set via the `QUERY_TAG` session parameter), which makes `QUERY_TAG` a practical attribution dimension (team/app/job) that can be rolled up alongside metering data.
   - Source: Snowflake docs for `QUERY_HISTORY` view.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse; `CREDITS_USED` includes compute + cloud services; view latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Has `QUERY_TAG`, `WAREHOUSE_NAME`, timings; can be used to attribute activity by tag/user/role/warehouse. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag relations only (no inheritance); includes `DOMAIN` and object identifiers/names. |
| Resource Monitors | Object | Snowflake object | Enforces warehouse credit quotas + actions; not for serverless/AI. |
| Tags | Object | Snowflake object | Tags can be assigned to warehouses; useful for resource usage monitoring & grouping. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Warehouse spend by tag” panel**: Daily/weekly rollup of `WAREHOUSE_METERING_HISTORY` credits grouped by tag dimensions from `TAG_REFERENCES` (e.g., `cost_center`, `env`, `owner_team`).

2. **Resource monitor coverage + gaps report**: List warehouses with/without a resource monitor + show current monitor schedule/quota vs trailing 7/30d burn (note: still misses serverless/AI). Use it to recommend monitor thresholds + buffers.

3. **Attribution policy checklist**: enforce/validate that (a) warehouses are tagged, and (b) critical jobs set `QUERY_TAG`. Report compliance rates using `QUERY_HISTORY.QUERY_TAG` null-rate by warehouse/team.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft — Daily credits by warehouse + direct tag attribution

```sql
/*
Goal:
- Attribute warehouse credits to tag dimensions (direct tag relations) for FinOps rollups.
- This uses ACCOUNT_USAGE views; expect latency (hours).

Notes:
- TAG_REFERENCES is direct-only (no inherited tags).
- WAREHOUSE_METERING_HISTORY is hourly; we roll up to day.
*/

ALTER SESSION SET TIMEZONE = UTC;

WITH metering_hourly AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used) AS credits_used,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_used_cloud_services) AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY 1, 2
),

warehouse_tags AS (
  SELECT
    object_name AS warehouse_name,
    /* Common FinOps dims (examples); extend as needed */
    MAX(IFF(tag_name = 'COST_CENTER', tag_value, NULL)) AS cost_center,
    MAX(IFF(tag_name = 'ENV', tag_value, NULL)) AS env,
    MAX(IFF(tag_name = 'OWNER_TEAM', tag_value, NULL)) AS owner_team
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
    AND object_deleted IS NULL
  GROUP BY 1
)

SELECT
  m.usage_date,
  COALESCE(t.cost_center, 'UNATTRIBUTED') AS cost_center,
  COALESCE(t.env, 'UNSPECIFIED') AS env,
  COALESCE(t.owner_team, 'UNATTRIBUTED') AS owner_team,
  m.warehouse_name,
  m.credits_used,
  m.credits_used_compute,
  m.credits_used_cloud_services,
  /* Optional: expose "idle" as metering compute minus query-attributed compute */
  (m.credits_used_compute - m.credits_attributed_compute_queries) AS credits_idle_compute_est
FROM metering_hourly m
LEFT JOIN warehouse_tags t
  ON t.warehouse_name = m.warehouse_name
ORDER BY 1, 2, 3, 4, 5;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES` excludes inherited tags. If customers rely on inheritance (e.g., tag on account → warehouses), attribution may look “missing”. | Misleading “UNATTRIBUTED” results. | Compare `ACCOUNT_USAGE.TAG_REFERENCES` with `...TAG_REFERENCES_WITH_LINEAGE` (function) for a sample account; document expected behavior in UI. |
| Joining tags by `warehouse_name` may be brittle if names change or if object name casing/quoting differs. | Wrong tag attribution after renames. | Prefer joining by `OBJECT_ID` → warehouse id where possible (requires confirming how to map warehouse IDs in available views). |
| `ACCOUNT_USAGE` latency (hours) means “near-real-time” dashboards will lag. | UI appears stale; alerts less actionable. | Offer “latency-aware” UX (timestamp of last data); optionally use event-based hooks for faster signals where feasible. |
| Resource monitors do not cover serverless/AI costs. | Incomplete cost guardrails if users assume “resource monitor = budget”. | Explicitly split “warehouse” vs “serverless/AI” spend; recommend budgets for non-warehouse. |

## Links & Citations

1. Working with resource monitors (limitations + actions + scheduling): https://docs.snowflake.com/en/user-guide/resource-monitors
2. `WAREHOUSE_METERING_HISTORY` view (columns + latency + hourly credits): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. `QUERY_HISTORY` view (`QUERY_TAG`, `WAREHOUSE_NAME`, etc.): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. `TAG_REFERENCES` view (direct tag relationships; no inheritance): https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
5. Introduction to object tagging (tags on warehouses for resource usage monitoring): https://docs.snowflake.com/en/user-guide/object-tagging/introduction

## Next Steps / Follow-ups

- Fetch + incorporate docs for **budgets** (since resource monitors explicitly don’t cover serverless/AI) and decide what a unified “guardrails” UX should look like.
- Validate the best-practice join key between tag references and warehouse metering (name vs ID) by checking the relevant warehouse inventory views/functions.
- Extend the SQL to compute $ cost using a configurable “credit price” and show compute vs cloud-services split separately.
