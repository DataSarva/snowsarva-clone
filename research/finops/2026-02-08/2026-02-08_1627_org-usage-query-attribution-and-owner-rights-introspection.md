# Research: FinOps - 2026-02-08

**Time:** 16:27 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added three **new ORGANIZATION_USAGE premium views** in the organization account: `METERING_HISTORY`, `NETWORK_POLICIES`, and `QUERY_ATTRIBUTION_HISTORY`. These are rolling out and should be available to all accounts by **Feb 9, 2026**.
2. `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` is explicitly intended to **attribute compute costs to specific queries run on warehouses across all accounts in the organization**, enabling org-wide chargeback/showback use cases.
3. In server release **10.3 (Feb 02–05, 2026)**, Snowflake expanded **owner’s rights contexts** (owner’s rights stored procedures, **Native Apps**, Streamlit) to allow broader introspection: most `SHOW`/`DESCRIBE` commands and access to `INFORMATION_SCHEMA` views and table functions, with history functions like `QUERY_HISTORY*` and `LOGIN_HISTORY_BY_USER` still restricted.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.METERING_HISTORY` | View | ORG_USAGE (premium) | Hourly credit usage for each account in the org. |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ORG_USAGE (premium) | Cross-account query-level cost attribution (compute) for warehouses. |
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | View | ORG_USAGE (premium) | Governance/security inventory across accounts (less FinOps, but valuable for posture). |
| Owner’s-rights contexts permissions (Native Apps / Streamlit / owner’s rights SPs) | Platform behavior | Release 10.3 | Enables INFOR
def schema + SHOW/DESCRIBE for in-app/admin introspection flows. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide chargeback/showback v1:** Use `ORG_USAGE.QUERY_ATTRIBUTION_HISTORY` to attribute warehouse compute to query fingerprints + user/role + tags, then roll up by cost center.
2. **Multi-account budget anomaly detection:** Combine `ORG_USAGE.METERING_HISTORY` with org/account metadata to detect spend spikes by account/region/warehouse.
3. **Native App “self-diagnostics” panel:** In an owner’s-rights SP inside the app, run allowed `SHOW`/`DESCRIBE` + `INFORMATION_SCHEMA` queries to validate required objects/privileges and render actionable remediation.

## Concrete Artifacts

### Draft SQL: Daily compute chargeback by account + warehouse

```sql
-- Pseudocode (column names to confirm from docs page for ORG_USAGE.QUERY_ATTRIBUTION_HISTORY)
-- Goal: daily compute attribution rollup for chargeback.

WITH q AS (
  SELECT
    /* expected */ account_name,
    /* expected */ warehouse_name,
    DATE_TRUNC('day', start_time) AS day,
    /* expected */ credits_used_compute AS credits
  FROM snowflake.organization_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
  account_name,
  warehouse_name,
  day,
  SUM(credits) AS credits_used_compute
FROM q
GROUP BY 1,2,3
ORDER BY day DESC, credits_used_compute DESC;
```

### Native App diagnostics: allowed introspection surface area

```sql
-- Illustrative only: owner’s-rights context now permits many SHOW/DESCRIBE + INFORMATION_SCHEMA
-- but still blocks QUERY_HISTORY* and LOGIN_HISTORY_BY_USER.

SHOW WAREHOUSES;
SHOW PARAMETERS IN ACCOUNT;

SELECT *
FROM my_db.information_schema.tables
WHERE table_schema = 'APP_SCHEMA';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ORG_USAGE.QUERY_ATTRIBUTION_HISTORY` column names, join keys, and latency semantics are unknown from the release-note blurb. | Could slow implementation / require schema discovery. | Read the full SQL reference page for the view and capture column list + examples. |
| Premium view availability/entitlement varies by org and rollout completes by Feb 9, 2026. | Feature may not work for all customers immediately. | In-app capability check: attempt minimal query and fall back gracefully. |
| Owner’s-rights contexts still restrict history functions; diagnostics may need alternative sources. | Limits “why did query X cost Y” in-app. | Confirm permitted surfaces; design diagnostics around `SHOW` + `INFORMATION_SCHEMA` + app-maintained telemetry. |

## Links & Citations

1. Feb 01, 2026: New ORGANIZATION_USAGE premium views — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. 10.3 Release Notes (Feb 02–05, 2026): Owner’s rights contexts introspection — https://docs.snowflake.com/en/release-notes/2026/10_3
3. ORGANIZATION_USAGE premium views overview — https://docs.snowflake.com/en/user-guide/organization-accounts-premium-views

## Next Steps / Follow-ups

- Pull the SQL reference for `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` and capture column list + 2-3 canonical rollups (by query, by user/role, by warehouse).
- Add an app-side “capability probe” query for these premium views (handles rollout/entitlement).
- Update our FinOps roadmap: org-wide chargeback becomes an early flagship feature once the view is generally available.
