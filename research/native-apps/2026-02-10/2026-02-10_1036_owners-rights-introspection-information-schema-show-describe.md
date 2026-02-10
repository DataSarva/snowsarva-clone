# Research: Native Apps - 2026-02-10

**Time:** 10:36 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake expanded **owner’s rights contexts** (including **Native Apps**) to allow a broader set of **introspection** operations.
2. In owner’s rights contexts, **most `SHOW` and `DESCRIBE` commands are now permitted**, with exceptions for commands that read domains tied to the current session/user.
3. In owner’s rights contexts, **`INFORMATION_SCHEMA` views and table functions are now accessible**, with specific history functions still restricted (notably `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER`).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views & table functions | Metadata views/TFs | INFO_SCHEMA | Newly accessible in owner’s rights contexts (with explicit exceptions for some history fns). |
| `SHOW ...` | Command | N/A | Most allowed in owner’s rights contexts; some session/user-scoped domains remain blocked. |
| `DESCRIBE ...` | Command | N/A | Most allowed in owner’s rights contexts; some session/user-scoped domains remain blocked. |
| `INFORMATION_SCHEMA.QUERY_HISTORY*` | Table function(s) | INFO_SCHEMA | **Still restricted** per release notes. |
| `INFORMATION_SCHEMA.LOGIN_HISTORY_BY_USER` | Table function | INFO_SCHEMA | **Still restricted** per release notes. |

## MVP Features Unlocked

1. **Self-diagnostics panel inside the Native App**: enumerate installed objects, versions, grants, and configuration using `INFORMATION_SCHEMA` + `SHOW`/`DESCRIBE` without requiring users to elevate roles outside the app.
2. **Automated compatibility checks** at runtime: verify required warehouses, integrations, network rules, database objects, and privileges exist (via `SHOW`/`DESCRIBE`) and present actionable remediation.
3. **Inventory-driven UX**: dynamic UI that lists available schemas/tables/views/functions the app can operate on by reading `INFORMATION_SCHEMA` instead of requiring manual input.

## Concrete Artifacts

### Owner-rights introspection (starter query sketch)

```sql
-- Pseudocode / sketch: exact objects depend on what Snowflake permits in the app's owner-rights context.
-- Goal: safely inventory accessible objects and surface missing prerequisites.

-- Example: list objects in current database/schema
SHOW TABLES IN SCHEMA <db>.<schema>;
SHOW VIEWS IN SCHEMA <db>.<schema>;

-- Example: use INFORMATION_SCHEMA for more structured metadata
SELECT table_schema, table_name, table_type
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE table_schema = '<schema>';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Which specific `SHOW`/`DESCRIBE` commands remain blocked in owner’s rights contexts isn’t exhaustively enumerated in the note. | Feature may fail for specific domains; needs defensive coding + fallback paths. | Test matrix in a scratch app across major domains (WAREHOUSES, INTEGRATIONS, NETWORK RULES, ROLES/GRANTS, etc.). |
| Some history-related introspection remains restricted. | App can’t rely on `QUERY_HISTORY`/login history from `INFORMATION_SCHEMA` in owner’s rights contexts. | Confirm restrictions in a real Native App runtime; document alternatives (e.g., approved views / telemetry collected by app). |

## Links & Citations

1. Snowflake Release Notes 10.3 (Feb 02–05, 2026) — “Owner’s rights contexts: Allow INFORMATION_SCHEMA, SHOW, and DESCRIBE” — https://docs.snowflake.com/en/release-notes/2026/10_3
2. Owner’s rights stored procedures (referenced by the release note) — https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-rights.html#label-stored-procedure-session-state-owners

## Next Steps / Follow-ups

- Build a small “introspection harness” procedure inside the Native App to empirically map which `SHOW`/`DESCRIBE` commands work vs. fail under owner’s rights.
- Update the app’s diagnostics module to prefer `INFORMATION_SCHEMA` over brittle parsing of `SHOW` output when possible.
- Decide how we want to handle query history requirements (telemetry collection vs. user-provided grants / optional elevated mode).
