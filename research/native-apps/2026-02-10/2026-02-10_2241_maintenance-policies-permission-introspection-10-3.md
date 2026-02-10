# Research: Native Apps - 2026-02-10

**Time:** 22:41 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Consumer-controlled maintenance policies** are in **public preview** for Snowflake Native Apps. Consumers can set a schedule window so upgrades **do not occur during specific time periods**; if a new release directive is set while a maintenance policy blocks the time, the upgrade is **delayed until the allowed start date/time**. 
2. Consumers create and manage maintenance windows for Native App upgrades using **SQL DDL**: `CREATE MAINTENANCE POLICY` and `ALTER MAINTENANCE POLICY`.
3. Snowflake’s **owner’s-rights permission model** (covering **owner’s-rights stored procedures, Native Apps, and Streamlit**) was updated in server release **10.3 (completed Feb 02–05, 2026)** to allow a much wider set of **introspection** operations:
   - **Most `SHOW` and `DESCRIBE` commands** are now permitted (with exceptions for commands tied to current session/user domains).
   - **INFORMATION_SCHEMA views and table functions** are now accessible.
   - Some **history functions remain restricted**, including `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `MAINTENANCE POLICY` | Object | SQL Reference | New consumer-controlled upgrade windowing for Native Apps is configured via maintenance policies (Preview). |
| `CREATE MAINTENANCE POLICY` | SQL command | SQL Reference | Creates a policy with a schedule that determines when upgrades may start. |
| `ALTER MAINTENANCE POLICY` | SQL command | SQL Reference | Applies/removes policy; used by consumers to control upgrade timing. |
| `INFORMATION_SCHEMA.*` | Views / table functions | 10.3 release note | Now accessible from owner’s-rights contexts (Native Apps/Streamlit/owner’s-rights SPs), with some history function exceptions. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“Safe upgrade window” UX inside the Native App**: add a setup screen that detects whether a maintenance policy is configured; if not, recommend one (esp. for enterprises) and provide copy-pastable SQL.
2. **Pre-upgrade / upgrade-readiness checklist**: because consumer upgrades can be delayed, surface a “pending upgrade readiness” view with compatibility checks (schemas, privileges, objects) that customers can run before allowing the maintenance window.
3. **Richer in-app diagnostics via introspection** (10.3): expand app-side “self-check” routines using `SHOW`/`DESCRIBE` and `INFORMATION_SCHEMA` to validate that required objects/privileges exist—without needing external admin scripts.

## Concrete Artifacts

### Copy/paste snippet (consumer guidance)

```sql
-- Consumer-controlled maintenance windowing for Native App upgrades (Preview)
-- (Exact syntax: see Snowflake SQL reference for CREATE/ALTER MAINTENANCE POLICY)

-- 1) Create a maintenance policy defining when upgrades are allowed to start
-- CREATE MAINTENANCE POLICY <name> ...

-- 2) Apply the policy (or remove it) as needed
-- ALTER MAINTENANCE POLICY <name> ...
```

### Owner’s-rights introspection: “safe” queries pattern

```sql
-- In owner’s-rights contexts (Native Apps / Streamlit / owner’s-rights SPs):
-- Prefer INFORMATION_SCHEMA and SHOW/DESCRIBE for introspection.
-- Avoid restricted history functions like QUERY_HISTORY / QUERY_HISTORY_BY_* / LOGIN_HISTORY_BY_USER.

SHOW WAREHOUSES;
SHOW ROLES;

-- Example: database/table metadata via INFORMATION_SCHEMA
SELECT *
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'PUBLIC';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Maintenance policies are **Preview** and semantics may change (syntax, scope, attach points). | App UX/docs could drift; automation may break. | Re-check SQL reference + Native App guide page each week until GA. |
| It’s unclear how maintenance policies interact with marketplace “release directives” lifecycle across multiple consumer accounts. | Provider operations workflows may need redesign. | Read the Native App “consumer maintenance policies” guide and test in a dev org. |
| Introspection allowances may vary by command and domain (SHOW/DESCRIBE exceptions). | Some checks may still fail inside the app. | Maintain an allowlist of commands tested in owner’s-rights contexts; add fallbacks. |

## Links & Citations

1. Consumer-controlled maintenance policies for Native Apps (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
2. Upcoming features summary (10.3-10.6): https://docs.snowflake.com/en/release-notes/2026/10_3-10_6
3. 10.3 release note — owner’s rights contexts allow INFORMATION_SCHEMA / SHOW / DESCRIBE: https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Read the full guide page linked from the release note (consumer maintenance policies) and extract exact SQL syntax + how it attaches to Native App upgrades.
- Add an internal design note: how our Native App should message “upgrade pending vs upgrade blocked by maintenance window” to avoid surprise outages.
- Extend our in-app diagnostics to leverage `INFORMATION_SCHEMA` + `SHOW`/`DESCRIBE` now that 10.3 is completed.
