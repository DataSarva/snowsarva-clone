# Research: FinOps - 2026-02-28

**Time:** 06:59 UTC  
**Topic:** Cost attribution primitives for a FinOps Native App (per-query compute + tag-based chargeback)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute credits** (`CREDITS_ATTRIBUTED_COMPUTE`) and explicitly **excludes warehouse idle time**; very short-running queries (≈<=100ms) are not included. ([Snowflake docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history))
2. Snowflake’s recommended cost attribution approach combines **object tags** (tag warehouses/users) with **query tags** (tag individual queries when an app runs queries on behalf of many teams). ([Snowflake docs](https://docs.snowflake.com/en/user-guide/cost-attributing))
3. To build cost reporting dashboards, Snowflake positions `ACCOUNT_USAGE` (single account) and `ORGANIZATION_USAGE` (org-wide) as the canonical analytics-ready sources; **per-query attribution is account-only** (no org-wide `QUERY_ATTRIBUTION_HISTORY` equivalent). ([Snowflake docs](https://docs.snowflake.com/en/user-guide/cost-attributing))
4. Cloud services credit consumption is not always billed; billed cloud services can be derived from `METERING_DAILY_HISTORY` (the docs note the 10% daily rule and recommend `METERING_DAILY_HISTORY` to compute what was actually billed). ([Snowflake docs](https://docs.snowflake.com/en/user-guide/cost-exploring-compute))

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | `ACCOUNT_USAGE` | Per-query compute credits for warehouse execution (`CREDITS_ATTRIBUTED_COMPUTE`), excludes idle; latency up to ~8 hours; short queries (~<=100ms) excluded. ([docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly credits used per warehouse; can be joined to tags (warehouse object tags) for showback/chargeback. ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | `ACCOUNT_USAGE` | Maps tags to objects; join patterns differ by `DOMAIN` (e.g., `WAREHOUSE`, `USER`). ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | `ACCOUNT_USAGE` | Used to compute billed cloud services via `credits_adjustment_cloud_services`. ([docs](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)) |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ORG_USAGE` | Org-wide warehouse metering; supports cost attribution across accounts for *dedicated* resources (when ownership is exclusive). ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | view | `ORG_USAGE` | Available only in the organization account; enables org-wide tag joins for supported scenarios (not per-query). ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Cost by Query Tag” daily materialization**: a scheduled job that aggregates `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG` (plus “untagged”), with optional proportional idle allocation using `WAREHOUSE_METERING_HISTORY` total credits. This is directly aligned with Snowflake’s example queries and becomes a reusable semantic table for the app UI.
2. **Tag hygiene / coverage report**: daily checks that identify (a) high-cost “untagged” spend, and (b) users/warehouses missing the required cost-center tag based on `TAG_REFERENCES` coverage and `QUERY_ATTRIBUTION_HISTORY` spend.
3. **Cost attribution “explainability” drill-down**: for any cost-center, show the top `QUERY_PARAMETERIZED_HASH` groups (recurrent query families) by attributed credits to quickly surface recurring expensive patterns. (`QUERY_PARAMETERIZED_HASH` is provided in `QUERY_ATTRIBUTION_HISTORY`.)

## Concrete Artifacts

### Artifact: SQL draft — daily cost by tag (with optional idle allocation)

Goal: produce a stable table/view the Native App can query, with both “active compute” (from per-query attribution) and “billed compute including idle” allocated proportionally.

```sql
-- COST BY QUERY TAG (DAILY)
-- Source views:
--   - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY (per-query compute credits, excludes idle)
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (warehouse total credits incl. idle)
--
-- Notes (from Snowflake docs):
--  - QUERY_ATTRIBUTION_HISTORY excludes idle time and omits very short queries (~<=100ms).
--  - View latency can be up to ~8 hours.

-- Parameters
SET start_date = DATEADD('day', -30, CURRENT_DATE());
SET end_date   = CURRENT_DATE();

WITH qah AS (
  SELECT
    TO_DATE(start_time)                                   AS usage_date,
    COALESCE(NULLIF(query_tag, ''), 'untagged')          AS query_tag_norm,
    SUM(credits_attributed_compute)                      AS active_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_date
    AND start_time <  $end_date
  GROUP BY 1, 2
),

-- Total active credits across tags per day (used for proportional idle allocation)
active_totals AS (
  SELECT
    usage_date,
    SUM(active_compute_credits) AS active_compute_credits_total
  FROM qah
  GROUP BY 1
),

-- Warehouse metering totals per day (includes idle + cloud services portion attributed to warehouses)
wh_totals AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used_compute) AS warehouse_compute_credits_total
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_date
    AND start_time <  $end_date
    AND warehouse_id > 0  -- skip pseudo VWs like CLOUD_SERVICES_ONLY if present in some accounts
  GROUP BY 1
)

SELECT
  qah.usage_date,
  qah.query_tag_norm                      AS query_tag,
  qah.active_compute_credits,

  -- Allocate total warehouse compute credits (incl. idle) proportionally to active usage by tag.
  -- This is the pattern used in Snowflake's attribution docs for distributing idle time.
  IFF(
    at.active_compute_credits_total = 0,
    NULL,
    qah.active_compute_credits / at.active_compute_credits_total * wt.warehouse_compute_credits_total
  ) AS allocated_warehouse_compute_credits_including_idle

FROM qah
JOIN active_totals at USING (usage_date)
LEFT JOIN wh_totals wt USING (usage_date)
ORDER BY usage_date DESC, active_compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Query attribution view latency (docs say up to ~8 hours) | “Near real-time” dashboards will look incomplete and may confuse users | In-app UI should label data freshness; compare “today” vs “yesterday” completeness; consider defaulting to D-1. ([docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)) |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time + short queries | Active credits won’t reconcile to total warehouse credits without an allocation step | Provide two metrics: active compute vs allocated including idle (proportional). ([docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)) |
| No org-wide per-query attribution view | App cannot do cross-account per-query chargeback purely in `ORG_USAGE` | Multi-account strategy likely needs: per-account ingestion/materialization, then consolidate in an org account (or accept per-account reporting). ([docs](https://docs.snowflake.com/en/user-guide/cost-attributing)) |
| Cloud services billed adjustment isn’t reflected in most “consumed credits” views | Spend in currency may not reconcile to invoiced billing | Use `METERING_DAILY_HISTORY` to compute billed cloud services and disclose difference between consumed vs billed. ([docs](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)) |

## Links & Citations

1. Snowflake docs — `QUERY_ATTRIBUTION_HISTORY` view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. Snowflake docs — Attributing cost (tags + example queries + org/account caveats): https://docs.snowflake.com/en/user-guide/cost-attributing
3. Snowflake docs — Exploring compute cost (schemas + billed cloud services + metering views): https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Draft a minimal **semantic schema** for the app (e.g., `FACT_COST_DAILY_BY_DIM`) that can ingest both per-query attribution outputs and metering outputs, with a consistent “consumed vs allocated vs billed” breakdown.
- Add a second artifact next: query patterns for **object tag-based attribution** (warehouse/user tag joins via `TAG_REFERENCES`) + coverage checks for missing tags.
