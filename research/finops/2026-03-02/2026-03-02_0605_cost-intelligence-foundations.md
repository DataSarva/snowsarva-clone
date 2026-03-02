# Research: FinOps - 2026-03-02

**Time:** 06:05 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s recommended approach for cost attribution is to use **object tags** to associate resources/users with cost centers and **query tags** to associate queries with a cost center when shared applications issue queries on behalf of multiple departments. (Snowflake docs)  
2. In a single account, cost attribution by tag in SQL commonly joins `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (warehouse-level) and/or `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute). (Snowflake docs)
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query attributed compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) but explicitly **excludes warehouse idle time**, and it can have up to ~8 hours of latency; very short-running queries (≈ <=100ms) are not included. (Snowflake docs)
4. There is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY` in `ORGANIZATION_USAGE`; org-wide attribution is available for some warehouse-level/tag views, but per-query attribution is account-scoped. (Snowflake docs)
5. The “cloud services layer” consumes credits, but **cloud services credits are billed only if daily cloud services consumption exceeds 10% of daily warehouse usage**; to determine billed credits, query `METERING_DAILY_HISTORY`. (Snowflake docs)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credit attribution (`CREDITS_ATTRIBUTED_COMPUTE`) excludes idle time; latency up to ~8h; short queries (~<=100ms) excluded. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credit usage; can be joined to tags for warehouse-level chargeback. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to objects (warehouses/users/etc) via `DOMAIN`, `OBJECT_ID`, `OBJECT_NAME`, `TAG_NAME`, `TAG_VALUE`. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide warehouse usage (warehouse-level), useful for multi-account spend, not per-query. |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | `ORG_USAGE` | Tag references at org scope; available only from the org account; join rules include tag DB/schema filters. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Source-of-truth for whether cloud services was billed (10% rule) via `CREDITS_ADJUSTMENT_CLOUD_SERVICES`. |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | `INFO_SCHEMA` | Only last 6 months; use `ACCOUNT_USAGE` view for complete long-range data. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Cost attribution “engine”**: Provide a canonical set of views (or a dynamic table) that produce: (a) per-query compute credits (native), (b) “reconciled” compute credits including allocated idle time, and (c) chargeback by `cost_center` derived from warehouse tags, user tags, and/or query tags.
2. **Tag coverage & hygiene report**: A daily job that shows “untagged” usage by warehouse/user/query_tag so teams can fix missing tags (high leverage, low complexity).
3. **Cloud services billing explainer**: A dashboard tile that compares `CREDITS_USED_CLOUD_SERVICES` vs billed cloud services using `METERING_DAILY_HISTORY` (the 10% threshold), to reduce confusion when consumption ≠ billed.

## Concrete Artifacts

### SQL Draft: Reconciled query-tag spend (allocate idle time back to query tags)

Goal: take the sum of per-query credits by `QUERY_TAG` (native attribution, excludes idle) and scale it to match metered warehouse compute credits for the same period. This yields “reconciled credits” that include idle time allocated proportionally to observed query-tag usage.

Notes:
- This is the same conceptual approach Snowflake shows for users/query tags (compute_credits * share_of_attributed_credits). (Snowflake docs)
- This produces a simple, explainable reconciliation, but it’s still an approximation (see risks).

```sql
-- Reconciled credits by query_tag (includes allocated idle time)
-- Period: last full month
WITH params AS (
  SELECT
    DATE_TRUNC('month', DATEADD('month', -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('month', CURRENT_DATE()) AS end_ts
),
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts FROM params)
),
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute)            AS attributed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= (SELECT start_ts FROM params)
    AND start_time <  (SELECT end_ts FROM params)
  GROUP BY 1
),
all_attributed AS (
  SELECT SUM(attributed_credits) AS total_attributed_credits
  FROM tag_credits
)
SELECT
  tc.query_tag,
  tc.attributed_credits,
  -- allocate idle/unattributed warehouse time proportionally
  tc.attributed_credits / NULLIF(a.total_attributed_credits, 0) * w.compute_credits AS reconciled_credits_incl_idle
FROM tag_credits tc
CROSS JOIN all_attributed a
CROSS JOIN wh_bill w
ORDER BY reconciled_credits_incl_idle DESC;
```

### SQL Draft: Warehouse-level chargeback by warehouse tag (dedicated warehouses)

```sql
-- Credits by warehouse tag_value (dedicated warehouses)
WITH params AS (
  SELECT
    DATE_TRUNC('month', DATEADD('month', -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('month', CURRENT_DATE()) AS end_ts
)
SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
WHERE wmh.start_time >= (SELECT start_ts FROM params)
  AND wmh.start_time <  (SELECT end_ts FROM params)
GROUP BY 1,2
ORDER BY total_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocating idle time proportionally to `QUERY_ATTRIBUTION_HISTORY` assumes idle should be spread by observed attributed usage. | Can mis-attribute idle-heavy warehouses (e.g., bursty workloads, auto-resume minimum billing windows). | Compare reconciled totals vs warehouse metering per warehouse/day; spot-check with known workloads. |
| `QUERY_ATTRIBUTION_HISTORY` excludes very short-running queries (~<=100ms) and has latency up to ~8 hours. | Dashboards can look “incomplete” or undercount compared to warehouse metering. | Document these caveats in UI and provide freshness indicator; reconcile with warehouse metering. |
| No org-wide equivalent for per-query attribution. | The app needs a per-account data pipeline or an org-account orchestrator that queries each account separately. | Validate customer org structure; plan multi-account ingestion strategy in native app. |
| Cloud services billing differs from raw consumption (10% rule). | Confusing or “inconsistent” billed vs consumed dashboards. | Use `METERING_DAILY_HISTORY` to show billed credits for cloud services; explain threshold. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history

## Next Steps / Follow-ups

- Draft an ADR for **multi-account ingestion** (org account orchestrates per-account `ACCOUNT_USAGE` queries; store results in an app-owned database) since per-query attribution is not org-scoped.
- Expand the “reconciled spend” model to optionally reconcile **per-warehouse** first, then roll up to tag/cost_center to avoid cross-warehouse bias.
- Add a “tag coverage score” metric: % of credits attributable to non-`untagged` tags at each attribution layer (warehouse tag, user tag, query tag).
