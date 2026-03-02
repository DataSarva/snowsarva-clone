# Research: FinOps - 2026-03-02

**Time:** 21:12 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for up to the last **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (which excludes warehouse idle time). Latency is typically up to **3 hours** (cloud services credit field can be up to **6 hours**). [1]
2. Snowflake distinguishes **credits consumed** vs **credits billed** for cloud services: cloud services credits are billed only if daily cloud services consumption exceeds **10%** of daily virtual warehouse usage; to compute billed credits you must use `METERING_DAILY_HISTORY` (not just raw cloud services credits from other views). [2]
3. Snowflake’s recommended cost attribution model uses **object tags** (tag warehouses/users) and **query tags** (tag queries issued by shared apps/workflows). In SQL, common attribution is joining `ACCOUNT_USAGE.TAG_REFERENCES` to usage views such as `WAREHOUSE_METERING_HISTORY`, and using `QUERY_ATTRIBUTION_HISTORY` for per-query compute credits. [3]
4. `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` is **account-scoped only**: Snowflake docs state there is **no organization-wide equivalent** in `ORGANIZATION_USAGE`. This matters for a multi-account “org rollup” FinOps Native App: org-wide query-level attribution must be computed per-account and aggregated externally (or via app orchestration) rather than a single org view. [3]
5. Both Snowflake docs and community investigation agree that query-level attribution **does not include warehouse idle time**; to reconcile “metered warehouse credits” to “attributed query credits”, you must model/allocate idle credits separately (e.g., proportionally by spend, or using an explicit idle timeline). [1][3][4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse; includes compute + cloud services; has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which excludes idle time; up to 365 days retention. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits; used to compute **billed** cloud services credits via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (docs recommend this view for billed compute). [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Query-level compute attribution for warehouse usage; docs emphasize it excludes idle time and excludes other cost types (storage, transfer, serverless, AI token costs). No org-wide equivalent. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tags to objects (domain like `WAREHOUSE` / `USER`); used to attribute warehouse costs by object tag. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Not the focus today, but commonly joined for query metadata; used by community to sanity-check query attribution and compute execution start time. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Fully-loaded compute by tag” metric**: expose two side-by-side numbers for the same slice (tag/user/query_tag):
   - **Attributed query credits** from `QUERY_ATTRIBUTION_HISTORY` (excludes idle)
   - **Fully-loaded compute credits** by allocating the account’s warehouse idle credits back onto tags proportionally (reconciles to `WAREHOUSE_METERING_HISTORY` totals). This can be the default for chargeback/showback.
2. **Cloud services billed-vs-consumed overlay**: a daily widget that shows
   - consumed cloud services credits (from metering/warehouse views)
   - billed cloud services credits using `METERING_DAILY_HISTORY` adjustment logic.
   This prevents “false alarms” when people chase cloud services credits that won’t be billed.
3. **Data freshness + latency guardrails**: surface view-specific “expected latency” and enforce a freshness watermark (e.g., don’t compute last-2-hours chargeback from `WAREHOUSE_METERING_HISTORY` due to documented latency). [1]

## Concrete Artifacts

### SQL: Compute credits by `COST_CENTER` warehouse tag + idle credits per warehouse

*Purpose*: provide (a) metered compute credits, (b) query-attributed credits, (c) derived idle credits, per warehouse and per day; a building block for a Native App “idle burn” insight.

```sql
-- Warehouse daily metering + idle credits (idle inferred from attribution-vs-metered)
-- Source semantics:
-- - WAREHOUSE_METERING_HISTORY is hourly (up to 1 year), compute credits include idle
-- - CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes idle time
-- Ref: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh_hour AS (
  SELECT
    start_time,
    TO_DATE(start_time) AS usage_date,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE warehouse_id > 0
    AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
),
wh_day AS (
  SELECT
    usage_date,
    warehouse_id,
    warehouse_name,
    SUM(credits_used_compute) AS compute_credits_metered,
    SUM(credits_attributed_compute_queries) AS compute_credits_attributed_to_queries,
    SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS compute_credits_idle
  FROM wh_hour
  GROUP BY 1,2,3
),
wh_tag AS (
  SELECT
    object_id AS warehouse_id,
    COALESCE(tag_value, 'untagged') AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND UPPER(tag_name) = 'COST_CENTER'
)
SELECT
  d.usage_date,
  COALESCE(t.cost_center, 'untagged') AS cost_center,
  SUM(d.compute_credits_metered) AS compute_credits_metered,
  SUM(d.compute_credits_attributed_to_queries) AS compute_credits_attributed_to_queries,
  SUM(d.compute_credits_idle) AS compute_credits_idle
FROM wh_day d
LEFT JOIN wh_tag t
  ON d.warehouse_id = t.warehouse_id
GROUP BY 1,2
ORDER BY 1 DESC, 2;
```

### SQL: “Fully-loaded compute credits by QUERY_TAG” (allocate idle proportionally)

*Purpose*: produce an **audit-friendly** daily chargeback table by query tag that reconciles to metered warehouse compute credits.

```sql
-- Fully-loaded chargeback by query_tag
-- - Base: query-attributed credits by query_tag (excludes idle)
-- - Reconciliation: allocate (metered - attributed) idle credits proportionally by tag spend
-- Ref: https://docs.snowflake.com/en/user-guide/cost-attributing

ALTER SESSION SET TIMEZONE = 'UTC';

SET start_date = DATEADD('day', -30, CURRENT_DATE());

WITH wh_bill AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE warehouse_id > 0
    AND start_time >= $start_date
  GROUP BY 1
),
tag_credits AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
    SUM(credits_attributed_compute) AS attributed_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_date
  GROUP BY 1,2
),
tag_totals AS (
  SELECT usage_date, SUM(attributed_compute_credits) AS total_attributed
  FROM tag_credits
  GROUP BY 1
)
SELECT
  tc.usage_date,
  tc.query_tag,
  tc.attributed_compute_credits,
  wb.metered_compute_credits,
  (wb.metered_compute_credits - tt.total_attributed) AS idle_compute_credits,
  -- Allocate idle proportionally by tag's share of attributed credits
  CASE
    WHEN tt.total_attributed = 0 THEN NULL
    ELSE (tc.attributed_compute_credits / tt.total_attributed) * (wb.metered_compute_credits - tt.total_attributed)
  END AS idle_allocated_to_tag,
  tc.attributed_compute_credits
    + COALESCE(idle_allocated_to_tag, 0) AS fully_loaded_compute_credits
FROM tag_credits tc
JOIN tag_totals tt
  ON tc.usage_date = tt.usage_date
JOIN wh_bill wb
  ON tc.usage_date = wb.usage_date
ORDER BY tc.usage_date DESC, fully_loaded_compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` may have edge-case accuracy issues for short queries / mismatch vs `QUERY_HISTORY` in some accounts (community-reported). | “Fully-loaded by query_tag” may drift or misattribute, even if it reconciles after idle allocation. | Validate against account-specific spot checks: pick one hour, compare sum(query credits) vs metered, and sanity-check top query IDs. Consider optional fallback “time-proportional” model using `QUERY_HISTORY` + `WAREHOUSE_METERING_HISTORY`. [4] |
| Billing vs consumption: many views report credits consumed without applying cloud services billing adjustment. | Executive dashboards may show inflated “cloud services cost” vs invoice. | Use `METERING_DAILY_HISTORY` for billed compute, and explicitly label consumed vs billed. [2] |
| Org-wide query attribution is not available as a single `ORG_USAGE` view. | Native App “org rollup query-tag chargeback” requires per-account ingestion/orchestration. | Confirmed in Snowflake doc: no org-wide equivalent of `QUERY_ATTRIBUTION_HISTORY`. [3] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. https://docs.snowflake.com/en/user-guide/cost-attributing
4. https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Add a **DQ check pack** to the app’s ingestion pipeline:
  - freshness watermark (e.g., ignore last N hours based on documented latency)
  - reconciliation check: `ABS(metered_compute - (attributed + idle))` should be ~0 at daily grain
  - coverage check: percent of credits tagged vs untagged.
- Decide on default idle allocation policy (proportional by tag/user vs explicit idle timeline) and document as an ADR.
