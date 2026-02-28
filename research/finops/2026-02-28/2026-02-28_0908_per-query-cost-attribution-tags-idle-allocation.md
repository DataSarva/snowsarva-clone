# Research: FinOps - 2026-02-28

**Time:** 09:08 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: use **object tags** to associate resources/users with cost centers, and **query tags** to associate individual queries with cost centers (especially when applications act on behalf of multiple users). (Snowflake docs) [1]
2. **WAREHOUSE_METERING_HISTORY** provides **hourly** warehouse credit usage and includes guidance/examples for computing **idle cost** as the difference between total compute credits and query-attributed compute credits; data latency can be **up to ~180 minutes** for most columns (and up to **6 hours** for cloud services credits). (Snowflake docs) [2]
3. **QUERY_ATTRIBUTION_HISTORY** can be used to determine **compute cost per query** (warehouse cost attribution), including query tag and user name dimensions. The per-query cost **does not include warehouse idle time** (idle time must be measured/attributed separately). (Snowflake docs) [1] [3]
4. Snowflake documents a pattern for **including idle time** by distributing warehouse-level credits across tags proportionally to their attributed credits over a period. (Snowflake docs) [1]
5. **Resource monitors** can control/avoid unexpected credit usage by monitoring credit usage for **warehouses** (and supporting cloud services), triggering actions (alerts/suspension) when thresholds/limits are reached; they **do not** track serverless features/AI services, and Snowflake recommends using a **budget** for those. (Snowflake docs) [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credit usage (last 365 days). Latency up to ~180 min (most columns) and up to ~6h for some cloud services credit columns. Includes example to compute idle cost. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute cost attribution; includes `QUERY_TAG`, `USER_NAME`, warehouse identifiers; cost excludes idle time. [3] [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query metadata including `QUERY_TAG` (useful for linking/query UX). [5] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags ↔ objects; used to attribute costs by warehouse/user via joins. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-level warehouse metering; Snowflake notes reconciliation needs session timezone = UTC in some cases (see `WAREHOUSE_METERING_HISTORY` docs). [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned by Snowflake for tracing stored procedures / root query id attribution patterns. [1] |
| `RESOURCE MONITORS` | Object | N/A | Cost controls for warehouses only; can suspend user-managed warehouses. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution v1 (per-query cost):** build a daily pipeline that aggregates `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG` (and/or `USER_NAME`) to produce a “cost by tag/user” table (compute + QAS credits), clearly labeling “excludes idle time”. [1] [3]
2. **Idle allocator:** compute warehouse-level idle credits from `WAREHOUSE_METERING_HISTORY` and optionally distribute idle credits across tags proportional to tag-level attributed compute credits (Snowflake-documented pattern). [1] [2]
3. **Controls posture scanner:** surface current resource monitors + thresholds, warn when none exist on high-spend warehouses, and link to recommended control patterns (alert thresholds + suspend behavior). [4]

## Concrete Artifacts

### SQL Draft: Daily cost attribution by query tag (with optional idle allocation)

Goal: produce a daily tag ledger for showback/chargeback.

Notes:
- This mirrors Snowflake’s documented approach (tagging + query tags + `QUERY_ATTRIBUTION_HISTORY`) and their example pattern for distributing idle time. [1]
- This draft assumes you use query tags of the form `COST_CENTER=<value>`; adapt parsing as needed.

```sql
-- Daily tag attribution (compute + QAS) from per-query costs.
-- Source of truth: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- Caveat: excludes idle time unless you allocate it separately.

WITH tag_credits AS (
  SELECT
      DATE_TRUNC('DAY', start_time) AS day,
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute) AS compute_credits,
      SUM(credits_used_query_acceleration) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
wh_bill AS (
  -- Warehouse-level total compute credits for same period.
  SELECT
      DATE_TRUNC('DAY', start_time) AS day,
      SUM(credits_used_compute) AS wh_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  GROUP BY 1
),
per_day_totals AS (
  SELECT
      day,
      SUM(compute_credits) AS sum_tag_compute_credits
  FROM tag_credits
  GROUP BY 1
),
idle_allocation AS (
  -- Allocate warehouse credits (incl. idle) across tags proportional to their compute credits.
  -- This follows the documented pattern; validate period alignment carefully. [1]
  SELECT
      tc.day,
      tc.tag,
      CASE
        WHEN t.sum_tag_compute_credits = 0 THEN 0
        ELSE (tc.compute_credits / t.sum_tag_compute_credits) * w.wh_compute_credits
      END AS attributed_compute_credits_including_idle,
      tc.compute_credits AS attributed_compute_credits_excluding_idle,
      tc.qas_credits
  FROM tag_credits tc
  JOIN per_day_totals t USING(day)
  JOIN wh_bill w USING(day)
)
SELECT *
FROM idle_allocation
ORDER BY day DESC, attributed_compute_credits_including_idle DESC;
```

### ADR Sketch: “Attribution correctness contract” (for the Native App)

**Decision:** expose two parallel metrics to users:
- **Per-query attributed compute credits** (from `QUERY_ATTRIBUTION_HISTORY`) — *excludes idle time*.
- **Warehouse metered compute credits** (from `WAREHOUSE_METERING_HISTORY`) — includes idle (and is the base for idle computation).

**Rationale:** Snowflake explicitly notes per-query cost excludes idle time, and provides a pattern to distribute idle time proportionally when needed. The app should be transparent about what’s being measured and how. [1] [2]

**Consequence:** all dashboards should label:
- latency expectations (hourly + up to hours delay)
- “idle included/excluded”

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` may not perfectly reconcile to billing or total metering without careful window alignment and timezone handling. | Users might see mismatches between “tag totals” and warehouse totals. | Add reconciliation checks per day; follow Snowflake notes on timezone alignment when reconciling with org views. [2] |
| Idle allocation “proportional to usage” may be politically or financially contentious. | Chargeback disputes. | Make allocation method configurable: none vs proportional vs warehouse-owner absorbs idle. Document default. [1] |
| Resource monitors do not cover serverless/AI features. | Blind spots in cost controls. | Add separate “budget” posture checks (requires further doc research on budgets). [4] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `WAREHOUSE_METERING_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. Snowflake Docs — Resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
5. Snowflake Docs — `QUERY_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Research Snowflake **Budgets** (controls for serverless/AI) and identify the governing views/objects for programmatic retrieval.
- Confirm any documented constraints around `QUERY_ATTRIBUTION_HISTORY` coverage windows / exclusions (e.g., short queries) by reading the official release note + view docs more deeply.
- Decide the Native App’s default “idle attribution policy” and represent it explicitly in the data model + UI.
