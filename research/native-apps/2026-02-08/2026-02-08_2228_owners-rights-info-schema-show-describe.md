# Research: Native Apps - 2026-02-08

**Time:** 22:28 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake server release **10.3 (Feb 02–05, 2026)** updates the permission model for **owner’s rights contexts** (explicitly including **Native Apps** and **Streamlit**) to allow a wider range of introspection commands. 
2. In these owner’s-rights contexts, **most `SHOW` and `DESCRIBE` commands are now permitted**, with exceptions for domains tied to the current session/user.
3. In these owner’s-rights contexts, **`INFORMATION_SCHEMA` views and table functions are now accessible**.
4. The following INFORMATION_SCHEMA history functions remain restricted: `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views/table functions | INFO_SCHEMA | Release 10.3 notes | Now accessible from owner’s-rights contexts (with history-function carve-outs). |
| `SHOW <object>` / `DESCRIBE <object>` | Command surface | Release 10.3 notes | Most allowed; still exceptions for session/user-related domains. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Native App self-diagnostics UI (no extra grants):** implement a “Diagnostics” page that runs `SHOW`/`DESCRIBE` and reads `INFORMATION_SCHEMA` to validate install health (objects present, versions, integration configuration) without asking customers to grant additional metadata privileges.
2. **In-app schema / object discovery:** enable guided setup that enumerates candidate databases/schemas/tables via `INFORMATION_SCHEMA` (within the app’s intended scope), reducing manual input and support load.
3. **Metadata-driven governance checks:** validate required policies (masking / tag presence) by inspecting `INFORMATION_SCHEMA` and reporting gaps directly in the app.

## Concrete Artifacts

### Minimal diagnostics query set (draft)

```sql
-- Pseudocode / examples; exact commands depend on which objects the app manages.

-- Discover schemas in the target database
SELECT schema_name
FROM <db>.information_schema.schemata
ORDER BY schema_name;

-- Discover tables in a schema
SELECT table_name, table_type
FROM <db>.information_schema.tables
WHERE table_schema = '<schema>'
ORDER BY table_name;

-- Introspection via SHOW/DESCRIBE (examples)
SHOW WAREHOUSES;
DESCRIBE WAREHOUSE <wh_name>;
SHOW ROLES;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Most SHOW/DESCRIBE permitted” still has meaningful exclusions depending on what we try to inspect (e.g., session/user-scoped domains). | Diagnostics may fail for some checks; need fallback guidance. | Enumerate the specific SHOW/DESCRIBE commands we rely on; test in a 10.3 account (or later) in an owner’s-rights stored procedure / native app context. |
| Access to INFO_SCHEMA may still be limited by database scope or object ownership patterns in customer environments. | Some discovery workflows may still require explicit setup/grants. | Validate against typical customer RBAC patterns; document required app roles/grants. |
| History functions remain restricted (`QUERY_HISTORY*`, `LOGIN_HISTORY_BY_USER`). | Query-level diagnostics must use other sources (e.g., ACCOUNT_USAGE/ORG_USAGE) if available/authorized. | Map diagnostics needs to alternative telemetry sources. |

## Links & Citations

1. Snowflake Release Notes 10.3 (Feb 02–05, 2026) — Extensibility updates: “Owner’s rights contexts: Allow INFORMATION_SCHEMA, SHOW, and DESCRIBE”: https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Identify the exact **SHOW/DESCRIBE** commands we want in the FinOps Native App (warehouses, resource monitors, databases/schemas, integrations, tasks, etc.) and verify they succeed from an owner’s-rights context.
- Draft a PR plan for a **Diagnostics** screen + backend stored proc wrapper, with a clear “what we can and can’t inspect” matrix.
