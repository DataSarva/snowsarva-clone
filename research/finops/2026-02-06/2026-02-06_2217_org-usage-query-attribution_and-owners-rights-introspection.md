# Research: FinOps - 2026-02-06

**Time:** 22:17 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added new **ORGANIZATION_USAGE premium views** in the **organization account** that provide org-wide visibility into usage and governance metadata across all accounts: **METERING_HISTORY**, **NETWORK_POLICIES**, and **QUERY_ATTRIBUTION_HISTORY**. These are rolling out gradually and expected to be available to all accounts by **2026-02-09**.
2. **ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY** is explicitly intended to **attribute compute costs to specific queries** run on warehouses across accounts (org-wide), which is a strong primitive for chargeback/showback and “top costly queries” workflows at org scope.
3. Snowflake updated **owner’s rights contexts** (owner’s rights stored procedures, **Native Apps**, Streamlit) to allow **INFORMATION_SCHEMA** access and most **SHOW/DESCRIBE** commands, enabling significantly more **introspection** from apps running in owner’s rights. History functions like **QUERY_HISTORY*** and **LOGIN_HISTORY_BY_USER** remain restricted.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| ORGANIZATION_USAGE.METERING_HISTORY | View | ORG_USAGE (premium) | Hourly credit usage per account (org-wide). |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ORG_USAGE (premium) | Attributes compute costs to specific queries run on warehouses (org-wide). |
| ORGANIZATION_USAGE.NETWORK_POLICIES | View | ORG_USAGE (premium) | Org-wide network policy inventory (governance lens; not FinOps directly, but useful). |
| INFORMATION_SCHEMA.* (in owner’s rights contexts) | Views/TFs | INFO_SCHEMA | Newly accessible from owner’s rights contexts, with exceptions. |
| SHOW / DESCRIBE (most) (in owner’s rights contexts) | Commands | SQL | Newly permitted for introspection; session/user domain exceptions remain. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide query cost leaderboard (preview):** Back a “Top costly queries across the org” UI/API using `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY`, with filters by account, warehouse, user/role, time bucket.
2. **Chargeback/showback v1:** Produce per-account chargeback rollups using `ORGANIZATION_USAGE.METERING_HISTORY`, optionally joined to org structures (cost centers) maintained in app tables.
3. **Native App self-diagnostics / environment introspection:** In owner’s rights contexts, use newly-allowed `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` to validate prerequisites (warehouse existence, grants, DB objects) and to power smarter setup checks without requiring manual admin steps.

## Concrete Artifacts

### SQL sketch: org-wide compute attribution (shape only)

```sql
-- NOTE: column names not validated here; treat as a shape sketch until we pull the SQL ref page.
-- Goal: top queries by attributed credits in last 7 days, org-wide.

SELECT
  account_name,
  warehouse_name,
  user_name,
  query_id,
  query_text,
  SUM(attributed_credits) AS attributed_credits,
  MIN(start_time) AS first_seen,
  MAX(start_time) AS last_seen
FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5
ORDER BY attributed_credits DESC
LIMIT 100;
```

### SQL sketch: org-wide metering rollup

```sql
SELECT
  account_name,
  DATE_TRUNC('day', start_time) AS day,
  SUM(credits_used) AS credits_used
FROM ORGANIZATION_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1,2
ORDER BY day DESC, credits_used DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE premium views availability/entitlement varies | Feature may not exist in all orgs immediately | Confirm presence in org account by 2026-02-09 and check docs for prerequisites/pricing. |
| Column names/types for QUERY_ATTRIBUTION_HISTORY differ from sketch | SQL may not run as-written | Pull the SQL reference page and pin exact schema into the app’s semantic layer. |
| Owner’s rights introspection still blocks some history and session/user domains | Some “diagnostics” still need delegated privileges or alternative telemetry | Prototype a minimal diagnostics SP and enumerate what’s blocked. |

## Links & Citations

1. New ORG_USAGE premium views (incl. QUERY_ATTRIBUTION_HISTORY): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Owner’s rights contexts: allow INFORMATION_SCHEMA, SHOW, DESCRIBE (Native Apps included): https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Pull SQL reference pages for the new views and capture exact column lists + retention/latency details.
- Prototype an org-account ingestion job that snapshots attribution + metering into app-managed tables for faster UI queries and trend modeling.
- Add a Native App “preflight” checklist that relies on the newly permitted `SHOW`/`DESCRIBE`/`INFORMATION_SCHEMA` surfaces.
