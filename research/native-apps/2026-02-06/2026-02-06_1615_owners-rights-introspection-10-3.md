# Research: Native Apps - 2026-02-06

**Time:** 16:15 UTC  
**Topic:** Snowflake Native App Framework (diagnostics + upgrade ergonomics)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Owner’s-rights contexts now allow most `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` access** (Snowflake server release **10.3**, Feb 02–05 2026). This applies to owner’s-rights stored procedures, **Native Apps**, and Streamlit.
2. **Some session/user history introspection is still blocked** in owner’s-rights contexts: `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER` remain restricted.
3. **Native App consumers can define maintenance windows for upgrades** (Preview): providers can set a new release directive, but consumer-defined maintenance policies can **delay** the upgrade until an allowed window.
4. **Release notes index (new-features page) indicates additional early-Feb 2026 feature updates** relevant to platform governance (e.g., listing/share observability adding new `INFORMATION_SCHEMA` + `ACCOUNT_USAGE` views), but those details weren’t fully extracted in this pass.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views + table functions (general) | Metadata | `INFO_SCHEMA` | Newly accessible from owner’s-rights contexts in 10.3 (exceptions apply). |
| `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, `LOGIN_HISTORY_BY_USER` | History functions | `INFO_SCHEMA` | Still restricted in owner’s-rights contexts (10.3). |
| `CREATE MAINTENANCE POLICY` / `ALTER MAINTENANCE POLICY` | DDL | SQL | Used by **consumers** to constrain when Native App upgrades can run (Preview). |

## MVP Features Unlocked

1. **In-app “Diagnostics / Support Bundle” that is safe under owner’s-rights**: collect `SHOW`/`DESCRIBE` outputs + selected `INFORMATION_SCHEMA` metadata to validate install state, granted privileges, object presence/shape, etc. (without requiring consumers to run manual scripts).
2. **Self-check / preflight installer**: during install/upgrade, run an owner’s-rights proc that verifies required objects exist (warehouses/compute pools/schemas/tables/roles/grants) by querying `INFORMATION_SCHEMA` + `SHOW`.
3. **Upgrade scheduling UX**: surface to consumers that upgrades can be delayed by their maintenance policy; add provider-side messaging + a “pending upgrade” state in the app UI.

## Concrete Artifacts

### Owner’s-rights diagnostics “preflight” (pseudocode)

```sql
-- Runs inside an owner's-rights stored procedure / app context
-- Goal: validate required objects & privileges without exposing data.

-- Examples of newly allowed introspection:
SHOW ROLES;
SHOW GRANTS TO APPLICATION <app_name>;  -- if supported in your account/edition

-- INFORMATION_SCHEMA checks (examples):
SELECT table_schema, table_name
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE table_schema = '<EXPECTED_SCHEMA>';

SELECT routine_schema, routine_name, routine_type
FROM <db>.INFORMATION_SCHEMA.ROUTINES
WHERE routine_schema = '<EXPECTED_SCHEMA>';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Most SHOW/DESCRIBE” is broad; specific commands may still be blocked depending on domain/session/user. | Diagnostics might fail in certain environments. | Test a curated allowlist of commands in a provider dev account + a consumer test account after 10.3 rollout. |
| `INFORMATION_SCHEMA` visibility can vary with privileges in the consumer account. | App may not see all objects unless privileges are granted. | Verify behavior under typical app privilege model; document minimal required grants for diagnostics. |
| Maintenance policies are in Preview; semantics could change. | UX/workflows might need adjustment. | Track release notes + validate in sandbox once available to target accounts. |

## Links & Citations

1. Snowflake 10.3 release notes (Feb 02–05, 2026): Owner’s rights contexts allow `INFORMATION_SCHEMA`, `SHOW`, `DESCRIBE` (with exceptions): https://docs.snowflake.com/en/release-notes/2026/10_3
2. Snowflake server release notes index (lists early Feb 2026 feature updates): https://docs.snowflake.com/en/release-notes/new-features
3. Consumer-controlled maintenance policies for Native Apps (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies

## Next Steps / Follow-ups

- Pull and summarize the **Feb 02, 2026 listing/share observability GA** page (new `INFORMATION_SCHEMA` + `ACCOUNT_USAGE` views) and map to FinOps/governance features.
- Draft an internal spec for a “Support Bundle” export format (JSON) with strict redaction rules.
- Add an integration test matrix for owner’s-rights introspection commands (positive/negative cases).