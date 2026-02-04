# Research: Native Apps - 2026-02-04

**Time:** 16:03 UTC  
**Topic:** Snowflake Native App Framework (release-note watch)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Owner’s-rights contexts** (including **Native Apps**, owner’s-rights stored procedures, and Streamlit) now permit **most SHOW/DESCRIBE commands** and allow access to **INFORMATION_SCHEMA views and table functions**, with specific exceptions for session/user history domains and certain history functions. (10.3 preview)
2. **Consumer-controlled maintenance policies** for **Snowflake Native Apps** are in **public preview**. Consumers can delay app upgrades into an allowed maintenance window; upgrades start when a new release directive is set, but will wait until the maintenance policy schedule allows. Consumers manage policies via **CREATE MAINTENANCE POLICY** and **ALTER MAINTENANCE POLICY**.
3. **Listing + share observability** is **GA**, adding new **INFORMATION_SCHEMA** views/table functions for realtime visibility and **ACCOUNT_USAGE** views for historical analysis (up to ~3h latency), plus enhanced **ACCOUNT_USAGE.ACCESS_HISTORY** coverage for listing/share DDL with details in `OBJECT_MODIFIED_BY_DDL`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA.*` | INFO_SCHEMA | 10.3 release notes | Now accessible from owner’s-rights contexts (Native Apps / OR SPs / Streamlit) with exceptions; history functions like `QUERY_HISTORY*` remain restricted. |
| `INFORMATION_SCHEMA.LISTINGS` | INFO_SCHEMA | Listing observability GA | Realtime view for providers; “no data latency”; does not include deleted objects. |
| `INFORMATION_SCHEMA.SHARES` | INFO_SCHEMA | Listing observability GA | Mirrors `SHOW SHARES` output; includes inbound/outbound shares. |
| `INFORMATION_SCHEMA.AVAILABLE_LISTINGS()` | INFO_SCHEMA | Listing observability GA | Table function for consumers; supports filters (e.g., `IS_IMPORTED => TRUE`). |
| `ACCOUNT_USAGE.LISTINGS` | ACCOUNT_USAGE | Listing observability GA | Historical listing analysis; includes dropped objects up to 1 year. |
| `ACCOUNT_USAGE.SHARES` | ACCOUNT_USAGE | Listing observability GA | Historical share analysis; includes dropped objects up to 1 year. |
| `ACCOUNT_USAGE.GRANTS_TO_SHARES` | ACCOUNT_USAGE | Listing observability GA | Historical grants/revokes to shares. |
| `ACCOUNT_USAGE.ACCESS_HISTORY` | ACCOUNT_USAGE | Listing observability GA | Now captures listing/share DDL lifecycle events; property diffs in `OBJECT_MODIFIED_BY_DDL` JSON. |
| `CREATE/ALTER MAINTENANCE POLICY` | SQL DDL | Native Apps maintenance policies | Consumer-controlled upgrade windows for Native Apps (preview). |

## MVP Features Unlocked

1. **Native App self-diagnostics page / “Support Bundle”**
   - Because `INFORMATION_SCHEMA` is now available in owner’s-rights contexts, an app can run richer, least-privilege introspection queries (e.g., list schemas/tables, objects, grants metadata depending on allowed views) and surface “what I can see” to help debug installs.
2. **Native App upgrade coordination UX**
   - Add a “maintenance window” / “upgrade scheduling” panel in the app (consumer side) that writes/updates a maintenance policy to reduce surprise upgrades for production accounts.
3. **Marketplace/Listing telemetry collector**
   - Use the new listing/share observability surfaces to build provider-facing dashboards (active shares, listing lifecycle, grants changes) and alert on unexpected DDL/property changes via `ACCESS_HISTORY.OBJECT_MODIFIED_BY_DDL`.

## Concrete Artifacts

### Example: listing visibility (consumer)

```sql
-- Realtime: list available marketplace listings to this account
SELECT *
FROM TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS());

-- Imported listings only
SELECT *
FROM TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS(IS_IMPORTED => TRUE));
```

### Example: listing/share DDL audit trail

```sql
-- Historical: detect listing/share lifecycle changes
SELECT
  event_timestamp,
  query_id,
  object_modified_by_ddl
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
WHERE object_modified_by_ddl IS NOT NULL
  -- NOTE: refine with JSON predicates for listing/share object types once confirmed in your account
ORDER BY event_timestamp DESC
LIMIT 200;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| 10.3 is preview and may shift before completion | Features/permissions might differ on release | Re-check 10.3 change log and validate in a non-prod account after rollout. |
| “Most SHOW/DESCRIBE” still has exceptions | Some diagnostics queries may still fail in owner’s-rights contexts | Enumerate required SHOW/DESCRIBE statements and test; implement graceful fallbacks. |
| Which JSON fields appear in `ACCESS_HISTORY.OBJECT_MODIFIED_BY_DDL` for listings/shares may vary | Harder to build stable parsers | Pull sample rows from real accounts and lock schemas/tests around observed shapes. |

## Links & Citations

1. 10.3 preview release notes (owner’s-rights contexts allow `INFORMATION_SCHEMA`, SHOW, DESCRIBE): https://docs.snowflake.com/en/release-notes/2026/10_3
2. Native Apps consumer-controlled maintenance policies (preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
3. Listing and share observability (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Validate which `INFORMATION_SCHEMA` objects are reachable specifically inside a Native App owner’s-rights context across editions/clouds.
- Prototype a minimal “Support Bundle” stored procedure for apps that runs a safe subset of `INFORMATION_SCHEMA` queries and returns JSON.
- Capture sample `OBJECT_MODIFIED_BY_DDL` payloads for listing/share events and design a stable parser + alert rules.
