# Research: FinOps - 2026-03-01

**Time:** 02:14 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution via tags + usage views)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s recommended approach to cost attribution is to use **object tags** (to associate resources/users with cost centers) and **query tags** (to attribute individual queries when an application runs queries on behalf of multiple cost centers). [Snowflake Docs: Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
2. For SQL-based attribution **within a single account**, Snowflake explicitly points to joining `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` with usage/cost views such as `WAREHOUSE_METERING_HISTORY` (warehouse credits) and `QUERY_ATTRIBUTION_HISTORY` (per-query compute attribution). [Snowflake Docs: Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
3. `QUERY_ATTRIBUTION_HISTORY` provides compute cost attribution at the query level but **does not include warehouse idle time**, nor other categories like storage/data transfer/cloud services/serverless features/AI tokens. [Snowflake Docs: Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
4. Resource monitors are a control mechanism for **warehouses only**; they can’t directly track serverless features and AI services (Snowflake recommends **budgets** for those). [Snowflake Docs: Resource monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)
5. Snowflake introduced/announced **tag-based budgets**: instead of selecting objects manually for a budget, you can scope a budget by an object tag (and leverage tag inheritance/precedence). The budget then tracks the combined costs of objects sharing the tag; updates reflect within hours and backfill for the current month. [Snowflake Engineering Blog: Tag-based budgets](https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/)
6. Snowflake’s Well-Architected (Cost Optimization/FinOps) guidance emphasizes a consistent tagging strategy, using `ACCOUNT_USAGE`/`ORGANIZATION_USAGE` telemetry, and combining tags + usage views to build showback/chargeback. [Snowflake Well-Architected Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | ACCOUNT_USAGE | Maps tagged objects/users to `tag_name`, `tag_value`, `domain`, `object_id/object_name`. Primary join point for tag attribution. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | ACCOUNT_USAGE | Hourly warehouse credit usage (compute credits). Often used as the “total bill” for warehouse compute to allocate. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | ACCOUNT_USAGE | Per-query compute credits attributed; excludes idle time and other cost categories (storage, data transfer, serverless, AI tokens). [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | view | ACCOUNT_USAGE | Holds `query_tag` (and many query metadata fields); useful when correlating query-level attribution back to workload/app patterns. [Well-Architected Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/) |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | view | ORG_USAGE | Org-wide tag references; doc note: in ORG_USAGE, `TAG_REFERENCES` is only available in the **organization account**. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | ORG_USAGE | Enables cross-account warehouse metering joins to tags for “exclusive resource” scenarios. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Tag coverage & enforcement dashboard (native app module):**
   - Show % of warehouse/user/database/schema objects missing required tags (e.g., `cost_center`, `env`, `owner_team`).
   - Provide a “fix-it” workflow (generate `ALTER <object> SET TAG ...` statements).
   - Rationale: Snowflake explicitly warns attribution breaks down without consistent tag enforcement; Well-Architected also calls this out. [Well-Architected Cost Optimization](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
2. **Monthly showback table: warehouse compute by tag with “idle allocation mode”:**
   - Mode A: “attributed-only” (sum `QUERY_ATTRIBUTION_HISTORY.credits_attributed_compute`) — excludes idle.
   - Mode B: “billed-proportional” (warehouse credits from `WAREHOUSE_METERING_HISTORY` allocated across tags proportional to query-attributed credits) — aligns to “what was billed” while staying explainable.
   - This matches Snowflake’s example approach of distributing idle time proportionally. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
3. **Guardrail recommendation engine:**
   - Detect warehouses without resource monitors, or monitors set to 100% suspend without buffer, and recommend “notify at 50/75, suspend at 90, suspend_immediate at 110” style controls.
   - Rationale: Snowflake suggests buffers and notes monitors are interval-based (not per-credit precision). [Resource monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)

## Concrete Artifacts

### SQL draft: Monthly compute showback by `cost_center` tag (dedicated warehouses)

This is the simplest, most reliable model: tag warehouses with `cost_center` and attribute warehouse credits directly.

```sql
-- Cost attribution for dedicated (non-shared) warehouses
-- Source pattern: Snowflake docs “Resources not shared by departments”
-- https://docs.snowflake.com/en/user-guide/cost-attributing

WITH wh_credits AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time,
    credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
    AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
),
wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND tag_name = 'COST_CENTER'
)
SELECT
  t.cost_center,
  SUM(c.credits_used_compute) AS warehouse_compute_credits
FROM wh_credits c
LEFT JOIN wh_tags t
  ON c.warehouse_id = t.warehouse_id
GROUP BY 1
ORDER BY warehouse_compute_credits DESC;
```

### SQL draft: “Billed-proportional” allocation for shared warehouses by query tag (includes idle)

This uses Snowflake’s documented pattern: allocate total warehouse credits (from `WAREHOUSE_METERING_HISTORY`) across tags in proportion to `QUERY_ATTRIBUTION_HISTORY` credits. This is explainable and reconciles to warehouse compute credits, but it is still an allocation (not a direct measurement of idle per tag).

```sql
-- Allocate total warehouse credits to query_tag in proportion to attributed query credits.
-- Pattern is based on Snowflake docs “Calculating the cost of queries (including idle time) by query tag”
-- https://docs.snowflake.com/en/user-guide/cost-attributing

WITH wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE)
    AND start_time <  CURRENT_DATE
),
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE)
  GROUP BY 1
),
all_credits AS (
  SELECT SUM(credits) AS sum_all_credits FROM tag_credits
)
SELECT
  tc.tag,
  (tc.credits / NULLIF(t.sum_all_credits, 0)) * w.compute_credits AS allocated_compute_credits_including_idle
FROM tag_credits tc
CROSS JOIN all_credits t
CROSS JOIN wh_bill w
ORDER BY allocated_compute_credits_including_idle DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Treating warehouse compute credits as the “bill” for compute showback is valid for the intended KPI | Works for warehouse compute but excludes serverless, AI, storage, and data transfer; app must label this clearly | Explicitly segment costs and show what’s in/out; Snowflake lists exclusions for query attribution. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| “Billed-proportional” idle allocation is acceptable for customers | Allocation may be contested vs. measuring true idle responsibility | Offer multiple modes (attributed-only vs billed-proportional); document methodology and tradeoffs. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing) |
| Resource monitors can be positioned as “cost control” | Resource monitors cannot control serverless/AI spend; may provide false sense of coverage | Explicitly highlight limitation and recommend budgets for serverless/AI. [Resource monitors](https://docs.snowflake.com/en/user-guide/resource-monitors) |
| Tag-based budgets will be available in target customer accounts | Availability/edition/region constraints may vary; blog describes capability but customers might not have it enabled | Detect feature availability and fall back to manual-scoped budgets; confirm via docs/DDL in later research. [Tag-based budgets blog](https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/) |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — Working with resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
3. Snowflake Engineering Blog — Tag-based budgets: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/
4. Snowflake Well-Architected Framework — Cost Optimization / FinOps guide: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Pull the **budget object** DDL + telemetry views (budgets / notifications / tag-based scoping details) and convert into a concrete “budget recommender” module spec.
- Explore org-wide constraints: `ORG_USAGE.TAG_REFERENCES` availability only in org account; design “org account collector” mode vs “single account mode”. [Attributing cost](https://docs.snowflake.com/en/user-guide/cost-attributing)
- Decide app UX: default to “warehouse compute showback” and progressively add serverless/AI cost categories (budget-based). [Resource monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)
