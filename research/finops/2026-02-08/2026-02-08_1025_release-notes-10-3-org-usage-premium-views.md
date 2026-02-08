# Research: FinOps - 2026-02-08

**Time:** 1025 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake added three **new ORGANIZATION_USAGE premium views** in the **organization account**: `ORGANIZATION_USAGE.METERING_HISTORY` (hourly credit usage per account), `ORGANIZATION_USAGE.NETWORK_POLICIES` (network policies across all accounts), and `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (attributes warehouse compute costs to specific queries across the org). [1]
2. Snowflake notes these ORGANIZATION_USAGE premium views are **rolling out gradually** and should be available to all accounts by **Feb 9, 2026**. [1]
3. In the 10.3 server release (Feb 2–5, 2026), Snowflake expanded **owner’s rights contexts** (owner’s rights stored procedures, **Native Apps**, Streamlit) to allow most `SHOW`/`DESCRIBE` commands and to allow access to `INFORMATION_SCHEMA` views/table functions, with some exceptions (notably query/login history functions). [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.METERING_HISTORY` | View (premium) | ORG_USAGE | Hourly credit usage per account in the org (org account). [1] |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View (premium) | ORG_USAGE | Query-level cost attribution for warehouse compute across the org. [1] |
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | View (premium) | ORG_USAGE | Inventory of network policies across all accounts (governance/controls signal). [1] |
| `<db>.INFORMATION_SCHEMA.*` (views/table functions) | Views/TFs | INFO_SCHEMA | Now accessible from owner’s rights contexts (incl. Native Apps), except certain history functions. [2] |
| `SHOW ...` / `DESCRIBE ...` (most) | Commands | n/a | Now permitted from owner’s rights contexts, with exceptions for session/user-scoped domains. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide hourly burn-rate + anomaly detection**: ingest `ORGANIZATION_USAGE.METERING_HISTORY` into the FinOps app to show hourly credits by account/region and flag sudden step-changes (e.g., 3-sigma over trailing 7d same-hour baseline). [1]
2. **Query-level cost attribution (org view)**: build a “Top expensive queries (org)” dashboard powered by `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY`, with drill-down to warehouse/account and a remediation checklist (warehouse sizing, clustering, caching, result reuse, task schedule). [1]
3. **Native App self-diagnostics without extra grants**: inside the app’s owner’s rights stored procedures, run safe `SHOW`/`DESCRIBE` + selected `INFORMATION_SCHEMA` queries to auto-detect misconfiguration (warehouse settings, privileges, missing objects) and render a preflight report. [2]

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Org hourly credits (starting point)

```sql
-- Org account
SELECT
  START_TIME,
  ACCOUNT_NAME,
  SERVICE_TYPE,
  CREDITS_USED
FROM ORGANIZATION_USAGE.METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;
```

### Query-level cost attribution (shape discovery)

```sql
-- Exact columns may vary; start with DESCRIBE/SELECT LIMIT to discover schema.
SELECT *
FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
QUALIFY ROW_NUMBER() OVER (ORDER BY START_TIME DESC) <= 1000;
```

### Native App / owner’s rights “introspection preflight” (examples)

```sql
-- Examples of commands/queries that should now work in owner’s rights contexts
SHOW WAREHOUSES;
DESCRIBE WAREHOUSE <name>;

SELECT *
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'PUBLIC'
LIMIT 50;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium ORG_USAGE views may require specific org-account entitlements / billing | Feature could be unavailable in some customer orgs; need graceful fallback | Verify access + error modes in a test org account; confirm prerequisites in premium-views docs. [1] |
| `QUERY_ATTRIBUTION_HISTORY` column set / semantics may differ from ACCOUNT_USAGE attribution views | Downstream dashboards may break if we assume columns | Start with schema discovery queries (`DESC VIEW`, `SELECT * LIMIT`) and pin to documented columns. [1] |
| Owner’s rights contexts still block certain session/user history functions (QUERY_HISTORY*, LOGIN_HISTORY_BY_USER) | App “preflight diagnostics” must avoid restricted functions or provide alternate signals | Validate allowed SHOW/DESCRIBE set and INFO_SCHEMA coverage in an app environment. [2] |

## Links & Citations

1. Feb 01, 2026 release note: “New ORGANIZATION_USAGE premium views” — lists `METERING_HISTORY`, `NETWORK_POLICIES`, `QUERY_ATTRIBUTION_HISTORY`, plus rollout note. https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. 10.3 server release notes (Feb 02–05, 2026): “Owner’s rights contexts: Allow INFORMATION_SCHEMA, SHOW, and DESCRIBE” (explicitly mentions Native Apps). https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Confirm whether `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` includes warehouse name/id, query_id, user/role, and credits attribution fields; document the minimal stable column subset for the app.
- Add a capability-detection routine in the Native App: check for ORG account + view availability, else degrade to per-account `ACCOUNT_USAGE` dashboards.
- Prototype an owner’s-rights “preflight” proc that runs a curated set of `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` queries and returns a JSON report for the UI.

