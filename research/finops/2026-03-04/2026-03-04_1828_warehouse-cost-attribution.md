# Research: FinOps - 2026-03-04

**Time:** 18:28 UTC  
**Topic:** Snowflake FinOps Cost Optimization (warehouse + query-level attribution; idle allocation)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is to use **object tags** to associate resources/users to cost centers, and **query tags** to associate per-query activity to a cost center when an application issues queries on behalf of multiple cost centers. [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) for the last **365 days**, but it **does not include warehouse idle time**, and **short-running queries (<= ~100ms) are excluded**. Data latency can be **up to ~8 hours**. [2]
3. `QUERY_ATTRIBUTION_HISTORY` has **no organization-wide equivalent** (i.e., there is no ORG_USAGE query-attribution view); Snowflake explicitly calls this out. [1]
4. Warehouse metering/billing is **per-second with a 60-second minimum** each time a warehouse starts/resumes (and also for certain resizes); suspending/resuming inside the first minute can create multiple 1-minute minimum charges. [3]
5. Snowflake’s doc examples explicitly show a pattern to “re-add” idle time by reconciling `WAREHOUSE_METERING_HISTORY` (metered warehouse credits) with `QUERY_ATTRIBUTION_HISTORY` (attributed query credits), distributing the delta proportionally across users or query tags. [1]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly warehouse compute credits metered (`CREDITS_USED_COMPUTE`). Used as “source of truth” for warehouse compute usage in doc examples. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | `ACCOUNT_USAGE` | Per-query compute credits attributed (`CREDITS_ATTRIBUTED_COMPUTE`) + query acceleration credits. Excludes idle; excludes <=~100ms queries; up to ~8h latency; 365d retention. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | `ACCOUNT_USAGE` | Mapping of objects to tag values. Used to join warehouses/users to cost center tags. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ORG_USAGE` | Org-wide warehouse metering (for org-level reporting in a single query). Snowflake doc shows this as the org-wide analog for *warehouse* credits. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | view | `ORG_USAGE` | Tag references at org scope, but Snowflake notes it’s only available in the organization account. Used for org-wide warehouse attribution. [1] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Idle-inclusive showback” primitive**: implement Snowflake’s documented “distribute idle delta proportionally” method for `QUERY_TAG` and `USER_NAME`. This yields a sane top-N cost center report even when warehouses have long auto-suspend windows.
2. **Tag hygiene report**: for a chosen tag key (e.g., `COST_CENTER`), report “% of credits untagged” at both levels:
   - warehouse-tagged attribution (dedicated warehouses) via `WAREHOUSE_METERING_HISTORY` + `TAG_REFERENCES` on domain `WAREHOUSE`
   - query-tag attribution (shared warehouses/apps) via `QUERY_ATTRIBUTION_HISTORY` grouped by `COALESCE(NULLIF(query_tag,''),'untagged')`
3. **Recurrent expensive workload finder**: use `QUERY_PARAMETERIZED_HASH` in `QUERY_ATTRIBUTION_HISTORY` to identify the most expensive recurring query shapes. (This is in Snowflake’s examples and is a great “optimization queue” input.) [1]

## Concrete Artifacts

### SQL: Allocate *metered* warehouse credits to `QUERY_TAG` (idle-inclusive)

This is essentially the Snowflake doc pattern, but framed as a reusable “semantic layer” query for a Native App.

```sql
-- Purpose:
--   Attribute warehouse compute credits (including idle time) to QUERY_TAG.
--   This reconciles metered warehouse credits with query-attributed credits,
--   distributing idle time proportionally to observed query-attributed credits.
--
-- Notes (from Snowflake docs):
--   - QUERY_ATTRIBUTION_HISTORY excludes idle time and excludes <=~100ms queries.
--   - Use WAREHOUSE_METERING_HISTORY as the metered warehouse compute credits source.
--
-- Time window: last full 30 days (adjust to taste)
WITH
  wh_metered AS (
    SELECT
      SUM(credits_used_compute) AS compute_credits
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD(day, -30, CURRENT_DATE)
      AND start_time < CURRENT_DATE
  ),

  tag_attributed AS (
    SELECT
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute) AS attributed_credits
    FROM snowflake.account_usage.query_attribution_history
    WHERE start_time >= DATEADD(day, -30, CURRENT_DATE)
      AND start_time < CURRENT_DATE
    GROUP BY 1
  ),

  total_attributed AS (
    SELECT SUM(attributed_credits) AS sum_all_attributed
    FROM tag_attributed
  )

SELECT
  t.tag,
  -- idle-inclusive credits: distribute metered credits proportionally
  (t.attributed_credits / NULLIF(a.sum_all_attributed, 0)) * w.compute_credits AS idle_inclusive_credits
FROM tag_attributed t
CROSS JOIN total_attributed a
CROSS JOIN wh_metered w
ORDER BY idle_inclusive_credits DESC;
```

**Why this matters for the Native App**
- It produces a stable “what did we pay for” number (metered warehouse credits) while still giving a cost-center breakdown.
- It makes the “untagged” bucket explicit, which is actionable.

### SQL: Attribute dedicated-warehouse credits by warehouse tag (`COST_CENTER`)

```sql
-- Attribute costs when warehouses are owned by a single cost center.
-- Join TAG_REFERENCES (domain='WAREHOUSE') to WAREHOUSE_METERING_HISTORY.
SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits
FROM snowflake.account_usage.warehouse_metering_history wmh
LEFT JOIN snowflake.account_usage.tag_references tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
WHERE wmh.start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
  AND wmh.start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY total_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes <=~100ms queries. | Under-attributes high-QPS “tiny query” workloads; idle-inclusive redistribution still won’t allocate those missing slices. | Compare `QUERY_HISTORY` volume vs `QUERY_ATTRIBUTION_HISTORY` coverage; quantify gap by warehouse/time. [2] |
| Latency up to ~8 hours in `QUERY_ATTRIBUTION_HISTORY`. | Near-real-time dashboards will be wrong/partial. | For UX, label time window as “complete through T-8h”; optionally backfill. [2] |
| “Proportional redistribution” assumes the relative shares in `QUERY_ATTRIBUTION_HISTORY` are a good proxy for distributing idle credits. | Potentially misallocates idle for workloads with very bursty patterns / concurrency. | Validate on a sample warehouse by comparing (a) per-tag sums vs (b) business expectations; consider warehouse-event-based modeling later. [1] |
| No org-wide query-attribution view exists. | Cross-account attribution by query/user/tag requires per-account processing. | Product architecture: run per-installed-account and roll up at the app’s control plane, not via ORG_USAGE. [1] |

## Links & Citations

1. Snowflake Docs — *Attributing cost* (tags + SQL patterns; notes on org vs account and idle redistribution examples): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — *QUERY_ATTRIBUTION_HISTORY view* (latency, <=~100ms exclusion, 365d retention, idle excluded): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — *Understanding compute cost* (per-second billing, 60-second minimum on resume; resize billing nuance; cloud services 10% rule): https://docs.snowflake.com/en/user-guide/cost-understanding-compute

## Next Steps / Follow-ups

- Convert the “idle-inclusive QUERY_TAG attribution” SQL into a **materialized daily aggregate** (e.g., `MC_FINOPS.DAILY_COST_BY_QUERY_TAG`) with a stable schema (date, tag_key, tag_value, credits_metered, credits_attributed, credits_idle_allocated).
- Add a “tag coverage” widget: `untagged_share = untagged_credits / total_credits` for both warehouse-tag and query-tag paths.
- Decide on product stance for cross-account org rollups given no `ORG_USAGE` query attribution: (a) per-account UI, or (b) central rollup in app backend.
