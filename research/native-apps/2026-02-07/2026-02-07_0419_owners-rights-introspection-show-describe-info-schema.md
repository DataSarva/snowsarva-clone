# Research: Native Apps - 2026-02-07

**Time:** 04:19 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. In the **10.3** server release (Feb 02–05, 2026), Snowflake expanded what can run inside **owner’s rights contexts** (explicitly including **owner’s rights stored procedures, Native Apps, and Streamlit**) to allow more **introspection**.
2. In owner’s rights contexts, **most `SHOW` and `DESCRIBE` commands** are now permitted; however, commands that read domains tied to the **current session/user** remain blocked.
3. In owner’s rights contexts, **`INFORMATION_SCHEMA` views and table functions are now accessible**, with specific restrictions that still apply to history functions: `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER` remain restricted.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views | INFO_SCHEMA | Release notes 10.3 | Now accessible in owner’s rights contexts (Native Apps, etc.). |
| `INFORMATION_SCHEMA` table functions | INFO_SCHEMA | Release notes 10.3 | Now accessible in owner’s rights contexts, except listed history functions. |
| `QUERY_HISTORY`, `QUERY_HISTORY_BY_*` | INFO_SCHEMA (history fns) | Release notes 10.3 | Explicitly still restricted in owner’s rights contexts. |
| `LOGIN_HISTORY_BY_USER` | INFO_SCHEMA (history fn) | Release notes 10.3 | Explicitly still restricted in owner’s rights contexts. |
| `SHOW ...` / `DESCRIBE ...` | SQL commands | Release notes 10.3 | “Most” are now permitted; some session/user scoped domains blocked. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“App self-diagnostics” page**: inside the Native App, run `SHOW`/`DESCRIBE`/`INFORMATION_SCHEMA` queries (where allowed) to validate required objects, grants, integrations, listings, and expose actionable error messages.
2. **Dynamic metadata-driven UI**: use `INFORMATION_SCHEMA` to discover schemas/tables/columns and drive configuration pickers (e.g., selecting cost tables, tags, or chargeback dimensions) without requiring external admin scripts.
3. **Safer permissions checks**: implement a permissions verification routine that uses allowed `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` access instead of relying on restricted history functions (and avoid over-privileging).

## Concrete Artifacts

### App Diagnostics Query Pack (starter)

```sql
-- NOTE: exact allowed SHOW/DESCRIBE surface is “most”; test in a target account.
-- Goal: validate environment, objects, and app prerequisites.

-- Example: enumerate objects in a target schema
SELECT table_schema, table_name
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE table_schema = '<SCHEMA>'
ORDER BY table_name;

-- Example: check expected views/functions exist
SELECT routine_schema, routine_name, routine_type
FROM <db>.INFORMATION_SCHEMA.ROUTINES
WHERE routine_name ILIKE 'FINOPS%';

-- Example: show grants for a role (if permitted)
-- SHOW GRANTS TO ROLE <role_name>;

-- Example: describe a service / integration / external access integration (if permitted)
-- DESCRIBE INTEGRATION <name>;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Most SHOW/DESCRIBE” may still exclude specific commands we need for FinOps/governance diagnostics. | App diagnostics could be incomplete or need fallbacks. | Validate command-by-command in an owner’s rights stored proc inside a test account running 10.3. |
| INFO_SCHEMA access is database-scoped; cross-db discovery may still require additional patterns. | UI discovery features may need explicit db selection / grants. | Confirm behavior in Native App context for multiple databases. |
| History functions remain restricted, so any “query history” based cost insights still require ACCOUNT_USAGE/ORG_USAGE (outside owner’s rights contexts) or separate privilege flows. | Limits “in-app” operational analytics without extra setup. | Decide on product stance: require explicit grants for ACCOUNT_USAGE/ORG_USAGE, or use event tables / app telemetry. |

## Links & Citations

1. Snowflake 10.3 Release Notes (Feb 02–05, 2026) — Owner’s rights contexts introspection expansion: https://docs.snowflake.com/en/release-notes/2026/10_3
2. Snowflake “Server release notes and feature updates” hub (for context / navigation): https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Build a tiny **compatibility test harness** (owner’s rights stored proc) that runs a curated list of `SHOW`/`DESCRIBE`/`INFORMATION_SCHEMA` queries and records pass/fail + error codes.
- Decide which diagnostics should run **inside** the app vs. in a separate admin workflow with elevated privileges.
