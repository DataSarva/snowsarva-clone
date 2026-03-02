# Research: FinOps - 2026-03-02

**Time:** 16:52 UTC  
**Topic:** Snowflake FinOps Cost Attribution using ACCOUNT_USAGE (QUERY_ATTRIBUTION_HISTORY + tags)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake recommends a cost attribution approach that combines **object tags** (to associate resources/users to cost centers) and **query tags** (to associate queries to cost centers when an app runs queries on behalf of multiple departments). 
2. Within an account, cost attribution by tag can be done by joining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` for warehouse-level usage and with `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` for query-level compute attribution.
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` attributes **warehouse compute credits to individual queries**; it **does not include warehouse idle time**, and it **excludes very short-running queries (<= ~100ms)**. Data latency can be **up to 8 hours**. 
4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` includes hourly warehouse credit usage and also provides `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which excludes idle time; the difference between `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` can be used to compute warehouse **idle-time credits**.
5. For organization-wide attribution: `TAG_REFERENCES` and `WAREHOUSE_METERING_HISTORY` exist in `SNOWFLAKE.ORGANIZATION_USAGE`, but **there is no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY` (query-level attribution is account-scoped).
6. Snowflake’s warehouse metering history view notes that to reconcile Account Usage with Organization Usage you should set `ALTER SESSION SET TIMEZONE = UTC` before querying Account Usage.
7. Snowflake introduced **tag-based budgets** (GA per blog post) that let a budget “monitor a specific tag” and backfill cost attribution changes for the **entire current month** once tags are updated (within “hours” per the post).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits; excludes warehouse idle time; excludes short queries (<= ~100ms); latency up to 8 hours. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits (compute + cloud services); has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which excludes idle time; notes timezone alignment when reconciling to ORG_USAGE. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Maps tags to objects (warehouses/users/etc.) for cost center attribution joins. Mentioned as key attribution join table. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Organization-wide hourly warehouse credits; usable for org-wide warehouse attribution. |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | ORG_USAGE | Only available in the **organization account**; usable for org-wide tagging joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | ACCOUNT_USAGE | Used to find root query id for stored procedures, which can then be used to roll up costs via `QUERY_ATTRIBUTION_HISTORY`. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App “Attribution Pack” views:** ship a set of views (or stored procedures that materialize tables) for: (a) warehouse credits by tag, (b) query credits by user tag, (c) query credits by query_tag, (d) idle credits by warehouse and period.
2. **Idle-time reconciliation module:** compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` per warehouse/time window and optionally distribute idle proportionally across (users | query_tag | cost_center tag) to reconcile to total warehouse compute.
3. **Tag hygiene report:** detect “top spend untagged” across warehouses, users, and query_tag (e.g., `untagged` buckets) and generate actionable remediation tasks.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: SQL draft — reconcile query attribution to metered warehouse compute (incl. idle) by query_tag

This produces a per-`query_tag` attribution that **reconciles** back to total warehouse compute credits for the window by allocating idle credits proportionally to query-attributed credits.

```sql
-- Inputs
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

-- 1) Total metered warehouse compute credits for the window
WITH wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
),

-- 2) Query-attributed credits by query tag (excludes idle by definition)
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_group,
    SUM(credits_attributed_compute) AS attributed_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1
),

-- 3) Sum of all query-attributed credits (denominator)
q_total AS (
  SELECT SUM(attributed_credits) AS sum_attributed
  FROM tag_credits
)

-- 4) Allocate metered warehouse compute (incl. idle) proportionally to query-attributed credits
SELECT
  tc.query_tag_group,
  tc.attributed_credits AS query_only_credits,
  (tc.attributed_credits / NULLIF(qt.sum_attributed, 0)) * wb.compute_credits AS reconciled_credits_including_idle
FROM tag_credits tc
CROSS JOIN q_total qt
CROSS JOIN wh_bill wb
ORDER BY reconciled_credits_including_idle DESC;
```

### Artifact: SQL draft — warehouse idle credits (diagnostic)

```sql
-- Warehouse idle credits for last 10 days (from Snowflake docs example)
SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits,
  warehouse_name
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('days', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY idle_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| `QUERY_ATTRIBUTION_HISTORY` excludes short queries (<= ~100ms). | Under-attribution for workloads with many tiny queries; reconciliation will shift more cost into the allocated-idle bucket. | Measure % of queries missing by joining to `QUERY_HISTORY` (assumption: `QUERY_HISTORY` coverage) and compare. |
| View latencies (up to 8h for QAH; up to 3h/6h for warehouse metering columns) | Near-real-time dashboards may be misleading; alerts could fire late. | Document expected delay; show “data freshness” timestamps in app. |
| Org-wide query-level attribution not available (no ORG_USAGE equivalent of QAH). | Native App “org rollups” must be warehouse-level only unless installed per-account and aggregated externally. | Confirm via docs; implement account-scoped modules + optional consolidation workflow. |
| Timezone mismatch when reconciling Account Usage vs Organization Usage. | Cross-schema reconciliation errors, especially around hour boundaries. | Enforce `ALTER SESSION SET TIMEZONE = UTC` for reconciliation queries. |

## Links & Citations

1. Snowflake Docs — Attributing cost (recommended tags + example SQL, and note that ORG_USAGE has no QAH equivalent): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view (latency, short query exclusion, idle-time exclusion): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` view (idle-time not included in attributed column; timezone note; idle example SQL): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. Snowflake Engineering Blog — Tag-based budgets GA and behavior (monitor tag; backfill current month): https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Next Steps / Follow-ups

- Add a Native App spec/ADR for an “Attribution Pack” schema: required grants, required views, and freshness/latency UX.
- Research whether budget objects / budget evaluation results are queryable via SQL/system views (for app integration), and whether they’re org-scoped.
- Explore a more accurate idle allocation method (e.g., allocate idle to “warehouse resume trigger” query) and assess feasibility with available ACCOUNT_USAGE views.
