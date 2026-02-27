# Research: FinOps - 2026-02-26

**Time:** 22:56 UTC  
**Topic:** Org-wide cost attribution: tags + ORGANIZATION_USAGE premium metering/query attribution (Feb 2026)
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended primitives for cost attribution are **object tags** (attach ownership to resources/users) and **query tags** (attach ownership to queries when a shared application issues queries on behalf of multiple cost centers). [1]
2. For **account-level** query cost attribution, `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides per-query compute credits (excluding idle time and excluding other non-warehouse costs like storage/transfer/serverless). [1]
3. `SNOWFLAKE.ORGANIZATION_USAGE` provides historical usage data across all accounts in an organization, and access is controlled via organization account application roles / database roles. [2]
4. Views in `SNOWFLAKE.ORGANIZATION_USAGE` that aggregate across all accounts and are only available in the **organization account** are considered **premium views** and **incur additional costs** based on records processed. [3]
5. As of Feb 2026 release notes, `SNOWFLAKE.ORGANIZATION_USAGE` includes new premium views `METERING_HISTORY` (hourly credits by account) and `QUERY_ATTRIBUTION_HISTORY` (org-wide query attribution), rolled out by ~Feb 9, 2026. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Objects/users with tags; join key patterns depend on domain (e.g., `WAREHOUSE_METERING_HISTORY.warehouse_id = TAG_REFERENCES.object_id` when `domain='WAREHOUSE'`). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Warehouse credit usage (warehouse-level; can allocate to warehouse tags). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query compute credits attributed; excludes idle time; no org-wide equivalent historically per attribution guide. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Allows warehouse credit usage across org; can join to org `TAG_REFERENCES` (org account only) to allocate for dedicated warehouses. [1][2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | ORG_USAGE | Only available in organization account; used for org-wide tag mapping. [1][2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` | View | ORG_USAGE (premium) | New Feb 2026 premium view: hourly credits by account (org-wide). [4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ORG_USAGE (premium) | New Feb 2026 premium view: org-wide query attribution. [4] (Also listed as a premium view in Organization Usage reference.) [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide showback baseline**: daily/hourly “cost by account” using `ORGANIZATION_USAGE.METERING_HISTORY` (or `...METERING_DAILY_HISTORY`) + contract/billing constraints noted (reseller/on-demand limitations). [2][4]
2. **Cost attribution by tag for dedicated warehouses across org**: use `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` joined to `ORGANIZATION_USAGE.TAG_REFERENCES` (org account only) with explicit `tag_database/tag_schema` filters (replicated tag DB pattern). [1]
3. **Org-wide query-level attribution (new premium view)**: build “top queries / top query_hash / top tags” across all accounts using `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY`, with safeguards to avoid `SELECT *` and to control premium-view scan cost (date filters, column projection, incremental materialization). [2][3][4]

## Concrete Artifacts

### ADR-0001 (Draft): Prefer org premium views for cross-account attribution, with cost controls

**Status:** Draft  
**Decision:** When operating in the organization account (or otherwise authorized), prefer `SNOWFLAKE.ORGANIZATION_USAGE` premium views to produce org-wide showback/chargeback and anomaly detection; otherwise fall back to per-account ingestion from `ACCOUNT_USAGE`.

**Rationale (from sources):**
- Org-wide aggregation exists in `ORGANIZATION_USAGE` and premium views are specifically intended to aggregate cross-account data. [2][3]
- Premium views incur extra costs; therefore our app should minimize scans (date predicates, column selection, incremental tables). [3]
- New Feb 2026 premium views add missing primitives for org-wide metering and query attribution. [4]

**Consequences:**
- The app needs a “mode switch”:
  - **Org mode** (best UX, fewer connectors) but premium view cost monitoring.
  - **Account mode** (deployable everywhere) with optional org roll-up by shipping per-account facts into the app.

### SQL Draft: Org-wide cost-by-tag for dedicated warehouses (monthly)

```sql
-- Purpose: Attribute warehouse compute credits across all accounts in an org
--          for warehouses that are owned by a single cost center (dedicated warehouses).
-- Runs in: ORGANIZATION ACCOUNT (needed for ORG_USAGE.TAG_REFERENCES).
-- Source pattern: Snowflake “Attributing cost” doc. [1]

-- Assumes tags live in COST_MANAGEMENT.TAGS and are replicated where needed.
-- Adjust tag_database/tag_schema/tag_name to match your implementation.

SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits
FROM snowflake.organization_usage.warehouse_metering_history wmh
LEFT JOIN snowflake.organization_usage.tag_references tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
 AND tr.tag_database = 'COST_MANAGEMENT'
 AND tr.tag_schema = 'TAGS'
 AND tr.tag_name = 'COST_CENTER'
WHERE wmh.start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
  AND wmh.start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
GROUP BY
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged')
ORDER BY total_credits DESC;
```

### SQL Draft: Cost-by-query-tag (account-level), plus idle-time reallocation

```sql
-- Purpose: Attribute compute by query_tag within an account and optionally
--          re-allocate warehouse idle time proportionally across tags.
-- Source pattern: Snowflake “Attributing cost” doc. [1]

WITH
  wh_bill AS (
    SELECT SUM(credits_used_compute) AS compute_credits
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE)
      AND start_time < CURRENT_DATE
  ),
  tag_credits AS (
    SELECT
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute) AS credits
    FROM snowflake.account_usage.query_attribution_history
    WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE)
    GROUP BY 1
  ),
  total_credit AS (
    SELECT SUM(credits) AS sum_all_credits
    FROM tag_credits
  )
SELECT
  tc.tag,
  tc.credits AS active_query_credits,
  (tc.credits / NULLIF(t.sum_all_credits, 0)) * w.compute_credits AS active_plus_idle_allocated_credits
FROM tag_credits tc
CROSS JOIN total_credit t
CROSS JOIN wh_bill w
ORDER BY active_plus_idle_allocated_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium views incur additional costs based on records processed. | If the app queries premium views naively (wide date ranges, `SELECT *`), it could materially increase Snowflake spend. | Enforce narrow predicates, column projection, incremental materialization; validate by measuring query profile + premium view billing. [3][2] |
| Not all orgs may have access to premium views (e.g., orgs without capacity contract; SnowGov region limitations; reseller constraints for billing views). | Some customers cannot use org mode; app needs fallback path. | Detect availability/permissions at install/runtime; document requirements. [2][3] |
| Release note extract via Parallel hit a cookie wall; we rely on search excerpts for the key claim about new views. | Slight risk of mis-stating view names/rollout date. | Re-validate via direct doc fetch / alternate extraction method; or confirm in Snowsight by describing the view. [4] |
| The Feb 2026 org-wide `QUERY_ATTRIBUTION_HISTORY` is described as “premium view”; exact columns/behavior may differ from account-level view. | Queries/joins may not port 1:1; needs schema discovery. | `DESC VIEW snowflake.organization_usage.query_attribution_history;` in org account and update transformations accordingly. [2][4] |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/sql-reference/organization-usage
3. https://docs.snowflake.com/en/user-guide/organization-accounts-premium-views
4. https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views

## Next Steps / Follow-ups

- Confirm the schema/columns of `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` and `...METERING_HISTORY` in a real org account; capture into a “golden” transformation spec (columns used, filters, retention/latency).
- Prototype an “Org mode cost controls” module: required predicates, max lookback, and incremental table design to cap premium view scan costs.
- Add an app permissions/availability check that detects: org account vs ORGADMIN-enabled account, premium view access, and required application/database roles. [2]
