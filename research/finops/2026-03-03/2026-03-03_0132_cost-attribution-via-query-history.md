# Research: FinOps - 2026-03-03

**Time:** 0132 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: **object tags** for resources/users (dept/project ownership) plus **query tags** for queries executed by shared applications on behalf of multiple departments. (Snowflake docs) [1]
2. Within a single account, Snowflake cost attribution by tag uses `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` joined to metering (`...WAREHOUSE_METERING_HISTORY`) and/or per-query attribution (`...QUERY_ATTRIBUTION_HISTORY`). Organization-wide attribution has an `ORGANIZATION_USAGE` equivalent for `WAREHOUSE_METERING_HISTORY` and `TAG_REFERENCES`, but **there is no ORG-wide equivalent of `QUERY_ATTRIBUTION_HISTORY`**. [1]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`), but **excludes warehouse idle time** and excludes other costs (e.g., serverless, storage, data transfer, tokens). It can have **up to ~8 hours latency** and **excludes very short-running queries (~<=100ms)**. [1][2]
4. When analyzing “billed” compute, be careful: cloud services credits are only billed if daily cloud services usage exceeds 10% of daily warehouse usage; Snowflake recommends using `METERING_DAILY_HISTORY` to determine billed credits for cloud services. [3]
5. For deeper per-query showback (including idle time), some teams implement custom allocation logic that starts from hourly truth (`WAREHOUSE_METERING_HISTORY`) and distributes credits across query + idle events on that hourly grain. (3rd-party analysis; validate vs your account) [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Which objects (WAREHOUSE/USER/etc) have what tag values; join key differs by domain (e.g., warehouse uses `object_id` = `warehouse_id`). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits for warehouses (compute + associated cloud services). Use as “metered truth” for warehouses. [1][3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query warehouse compute credits (no idle). Includes multi-cluster/autoscaling in attribution; has latency; excludes short queries. [1][2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to enrich query attribution with query text/type/role, etc; used for cloud-services credits per query via `CREDITS_USED_CLOUD_SERVICES` (not included in `QUERY_ATTRIBUTION_HISTORY`). [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily metering; use to compute what cloud-services credits were actually billed via adjustments. [3] |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | `ORG_USAGE` | Tag references across accounts, but **only available in the org account**. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Warehouse metering across accounts. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | `ACCOUNT_USAGE` | Useful for suspend/resume event timing when building a custom idle-time model; reliability/semantics need validation per account. (3rd-party discussion; treat as assumption) [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Tag coverage guardrails (FinOps hygiene):** a daily job that reports % of credits on **untagged** warehouses/users/query_tags, using `TAG_REFERENCES + WAREHOUSE_METERING_HISTORY + QUERY_ATTRIBUTION_HISTORY`. Include “top offenders” lists + owner routing. [1]
2. **Query-tag chargeback dashboard (with reconciliation):** show compute credits by `QUERY_TAG` using `QUERY_ATTRIBUTION_HISTORY` and provide an “include idle time” toggle that allocates the metered warehouse delta (metered credits minus attributed query credits) proportionally (or using a more sophisticated idle model). [1][2][4]
3. **“Billed vs consumed” explainer widget:** show that cloud services credits are only billed after the 10% threshold; drive calculations off `METERING_DAILY_HISTORY` for billed cloud-services and highlight difference vs “consumed credits” shown elsewhere. [3]

## Concrete Artifacts

### Artifact: Monthly compute credits by QUERY_TAG with proportional idle allocation (reconciling to metered warehouse credits)

Goal: produce a dataset suitable for the Native App to power a “chargeback by query_tag” view that reconciles to metered warehouse credits (compute). This uses Snowflake’s recommended approach of query tags + `QUERY_ATTRIBUTION_HISTORY`, then allocates idle proportionally (same concept as Snowflake’s docs examples). [1][2]

```sql
-- Chargeback by QUERY_TAG (excluding vs including idle time)
-- Source of truth for metered warehouse compute credits: WAREHOUSE_METERING_HISTORY
-- Source of truth for per-query compute credits (no idle): QUERY_ATTRIBUTION_HISTORY
--
-- Notes:
-- - QUERY_ATTRIBUTION_HISTORY: excludes idle time and short queries (<=~100ms) and can lag up to ~8h. [2]
-- - WAREHOUSE_METERING_HISTORY is hourly. [3]
-- - This allocates idle proportionally by each tag's attributed credits.
--
-- Parameters
SET start_ts = DATEADD('MONTH', -1, DATE_TRUNC('MONTH', CURRENT_DATE()));
SET end_ts   = DATE_TRUNC('MONTH', CURRENT_DATE());

WITH
wh_metered AS (
  SELECT
    SUM(credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
    AND warehouse_id > 0  -- skip pseudo warehouses
),

qah_by_tag AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS attributed_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1
),

qah_total AS (
  SELECT SUM(attributed_compute_credits) AS total_attributed
  FROM qah_by_tag
),

final AS (
  SELECT
    t.tag,
    t.attributed_compute_credits,

    -- "Idle" here means metered warehouse compute not attributed to any query in QAH.
    -- This includes true idle time + anything QAH doesn't capture.
    (w.metered_compute_credits - qt.total_attributed) AS unallocated_metered_compute,

    -- Allocate unallocated compute proportionally to each tag's share of attributed credits.
    CASE
      WHEN qt.total_attributed = 0 THEN NULL
      ELSE t.attributed_compute_credits / qt.total_attributed * (w.metered_compute_credits - qt.total_attributed)
    END AS allocated_unallocated_compute,

    -- Reconciled "including idle" chargeback
    CASE
      WHEN qt.total_attributed = 0 THEN w.metered_compute_credits
      ELSE t.attributed_compute_credits
           + (t.attributed_compute_credits / qt.total_attributed) * (w.metered_compute_credits - qt.total_attributed)
    END AS chargeback_compute_credits_including_idle

  FROM qah_by_tag t
  CROSS JOIN wh_metered w
  CROSS JOIN qah_total qt
)
SELECT *
FROM final
ORDER BY chargeback_compute_credits_including_idle DESC;
```

### Artifact: “Untagged hygiene” check (warehouses)

```sql
-- Identify metered credits by warehouse tag (or untagged)
SET start_ts = DATEADD('MONTH', -1, DATE_TRUNC('MONTH', CURRENT_DATE()));
SET end_ts   = DATE_TRUNC('MONTH', CURRENT_DATE());

SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_compute_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
WHERE wmh.start_time >= $start_ts
  AND wmh.start_time <  $end_ts
GROUP BY 1, 2
ORDER BY 3 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short-running queries, and can lag hours. | “Cost per query/tag” can undercount vs metered credits; reconciliation needed; near-real-time dashboards can be misleading. | Confirm expected gaps by comparing `SUM(credits_attributed_compute)` vs `SUM(credits_used_compute)` for the same window; document typical delta in the app. [2] |
| “Unallocated metered compute” is treated as idle in the proportional allocation artifact. | If the delta includes other effects (e.g., QAH omissions), the “idle” label may be incorrect. | Rename metric to “unallocated metered compute” in UI; optionally implement a more explicit idle model. [1][2] |
| Warehouse metering includes associated cloud services; billed cloud services may have daily adjustments. | Confusion between consumed vs billed credits; inaccurate dollarization. | Use `METERING_DAILY_HISTORY` for billed cloud services and/or `USAGE_IN_CURRENCY_DAILY` for currency conversions as recommended. [3] |
| Using `WAREHOUSE_EVENTS_HISTORY` for suspension/idle modeling depends on event semantics and reliability. | A custom idle model can be wrong or expensive to compute. | Prototype on one warehouse for 15 days; compare inferred idle to operational expectations; consider fallback to proportional allocation. [4] |

## Links & Citations

1. Snowflake Docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` reference & usage notes: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Exploring compute cost (incl. metering views + billing nuance): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Greybeam analysis — Query cost attribution + idle modeling approach (validate independently): https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a Native App “data contract” around required privileges/roles for cost views (e.g., `USAGE_VIEWER` / `GOVERNANCE_VIEWER` for QAH). [2]
- Decide on MVP reconciliation strategy:
  - v1: proportional allocation (fast, simple, reconciling)
  - v2: event-based idle allocation model (more precise; more compute and more assumptions)
- Extend to org-level showback: warehouse + tag at org scope (`ORGANIZATION_USAGE`) where possible; annotate that QAH is account-scoped only. [1]
