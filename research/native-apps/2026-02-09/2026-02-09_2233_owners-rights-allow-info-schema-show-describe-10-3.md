# Research: Native Apps - 2026-02-09

**Time:** 2233 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. In Snowflake server release **10.3 (Feb 02–05, 2026)**, **owner’s rights contexts** (including **owner’s rights stored procedures, Native Apps, and Streamlit**) were updated to allow a wider range of introspection commands, notably **most `SHOW` and `DESCRIBE`** commands. 
2. In the same update, **`INFORMATION_SCHEMA` views and table functions are now accessible** from these owner’s rights contexts.
3. Some history functions remain restricted in `INFORMATION_SCHEMA`, including **`QUERY_HISTORY`**, **`QUERY_HISTORY_BY_*`**, and **`LOGIN_HISTORY_BY_USER`**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views + table functions (broadly) | Metadata | INFO_SCHEMA | Newly permitted from owner’s rights contexts (with exceptions). |
| `INFORMATION_SCHEMA.QUERY_HISTORY*` | History | INFO_SCHEMA | **Still restricted** in owner’s rights contexts per release notes. |
| `INFORMATION_SCHEMA.LOGIN_HISTORY_BY_USER` | History | INFO_SCHEMA | **Still restricted** in owner’s rights contexts per release notes. |
| `SHOW <object>` / `DESCRIBE <object>` (most) | Introspection commands | SQL | Newly permitted from owner’s rights contexts (with some domain/session/user-related exceptions). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **In-app metadata inventory (safe introspection mode):** inside the Native App’s owner-rights stored proc(s), use `SHOW`/`DESCRIBE` + allowed `INFORMATION_SCHEMA` to inventory warehouses, databases/schemas, resource monitors, tags, etc. This enables a "what do you have + how is it configured" view without requiring the consumer to grant broad read privileges.
2. **Self-diagnosis + permissions health checks:** add an "introspection diagnostics" page that runs a small battery of allowed `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` queries and reports what’s blocked (vs allowed), so support can quickly determine why a feature can’t see certain metadata.
3. **Guardrails & policy validation:** implement checks that validate recommended configuration (auto-suspend, multi-cluster settings, query acceleration, etc.) by reading live object definitions (`DESCRIBE WAREHOUSE`, etc.) rather than requiring manual input.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Minimal introspection battery (owner-rights context)

```sql
-- Run from an owner-rights stored procedure inside the Native App.
-- Goal: establish what is now possible and where hard blocks still exist.

-- 1) SHOW / DESCRIBE examples (should largely work now)
SHOW WAREHOUSES;
SHOW RESOURCE MONITORS;
SHOW DATABASES;

-- Warehouse config inspection
-- (If DESCRIBE is permitted for this object type in your environment)
DESCRIBE WAREHOUSE <warehouse_name>;

-- 2) INFORMATION_SCHEMA examples (now accessible, with exceptions)
SELECT *
FROM INFORMATION_SCHEMA.SCHEMATA
LIMIT 50;

-- 3) Expected-to-fail history calls (document the restriction)
-- These are called out as still restricted in the release notes.
SELECT * FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY()) LIMIT 1;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Most” `SHOW`/`DESCRIBE` are allowed, but **some domains remain blocked** (session/user-related). | Some inventory checks may still fail depending on object type / context. | Build the introspection battery above; record failures by command + error code; keep an allowlist of safe statements. |
| `INFORMATION_SCHEMA` history functions remain restricted (`QUERY_HISTORY*`, `LOGIN_HISTORY_BY_USER`). | In-app query history style features can’t rely on these functions from owner-rights contexts. | Use alternative telemetry (Event Tables) or require explicit grants / consumer-provided views when needed. |
| Behavior might differ across editions/regions/rollout timing. | Users on older releases won’t have it yet. | Detect `CURRENT_VERSION()`/release in-app and degrade gracefully. |

## Links & Citations

1. Snowflake Server Release Notes 10.3 (Feb 02–05, 2026) — Owner’s rights contexts: Allow INFORMATION_SCHEMA, SHOW, and DESCRIBE: https://docs.snowflake.com/en/release-notes/2026/10_3
2. Owner’s rights stored procedures (rights model / session-state notes): https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-rights.html#label-stored-procedure-session-state-owners

## Next Steps / Follow-ups

- Add an “Introspection capability matrix” doc/table to the Native App repo: commands we use (`SHOW`, `DESCRIBE`, `INFORMATION_SCHEMA`) + minimum server version + known exceptions.
- Prototype the introspection battery in a minimal owner-rights stored procedure and capture real error strings/codes for blocked statements.
- Decide how we want to surface this in-product (admin diagnostics page vs silent capability detection).

