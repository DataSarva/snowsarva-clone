# Research: FinOps - 2026-02-07

**Time:** 10:20 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added three new **ORGANIZATION_USAGE premium views** (rollout completes by **Feb 9, 2026**) in the **organization account**: `ORGANIZATION_USAGE.METERING_HISTORY`, `ORGANIZATION_USAGE.NETWORK_POLICIES`, and `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY`. These provide hourly credit usage by account, network policy inventory across accounts, and warehouse compute cost attribution to queries across the org. 
2. In server release **10.3 (Feb 02–05, 2026)**, Snowflake expanded **owner’s rights contexts** (explicitly including **Native Apps** and **Streamlit**) to allow broader introspection: **most `SHOW`/`DESCRIBE`** commands and access to **`INFORMATION_SCHEMA` views and table functions** (with explicit restrictions on certain history functions like `QUERY_HISTORY*` and `LOGIN_HISTORY_BY_USER`).
3. Snowflake released **listing/share observability GA (Feb 02, 2026)**, adding new `INFORMATION_SCHEMA` views/table functions and new/updated `ACCOUNT_USAGE` views (plus expanded `ACCOUNT_USAGE.ACCESS_HISTORY`) that improve auditing and historical analysis for Marketplace/listing + share lifecycle events.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.METERING_HISTORY` | ORG_USAGE (premium view) | Release note (Feb 01, 2026) | Hourly credit usage **per account** across the org. Useful for chargeback/showback and cross-account anomaly detection. |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | ORG_USAGE (premium view) | Release note (Feb 01, 2026) | Attributes warehouse compute costs to specific queries across the org. (Exact grain/columns need review in the view reference.) |
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | ORG_USAGE (premium view) | Release note (Feb 01, 2026) | Inventory + governance visibility across accounts. Not FinOps directly, but governance/controls at org scale. |
| `<db>.INFORMATION_SCHEMA.*` (views + table functions) | INFO_SCHEMA | 10.3 release note | Now accessible inside owner’s rights contexts (Native Apps / Streamlit / owner’s rights stored procs), except certain history functions. |
| `<db>.INFORMATION_SCHEMA.LISTINGS` | INFO_SCHEMA | Release note (Feb 02, 2026) | Real-time listing visibility for provider roles. |
| `<db>.INFORMATION_SCHEMA.SHARES` | INFO_SCHEMA | Release note (Feb 02, 2026) | Similar to `SHOW SHARES`, includes inbound/outbound shares. |
| `<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS()` | INFO_SCHEMA (table function) | Release note (Feb 02, 2026) | Discoverable/accessible listings for consumers, with filters. |
| `SNOWFLAKE.ACCOUNT_USAGE.LISTINGS` | ACCOUNT_USAGE | Release note (Feb 02, 2026) | Historical analysis (up to ~3h latency); includes dropped listings. |
| `SNOWFLAKE.ACCOUNT_USAGE.SHARES` | ACCOUNT_USAGE | Release note (Feb 02, 2026) | Historical analysis; includes dropped shares. |
| `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES` | ACCOUNT_USAGE | Release note (Feb 02, 2026) | Historical grants/revokes to shares. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | ACCOUNT_USAGE | Release note (Feb 02, 2026) | Now captures listing/share DDL lifecycle events + detailed property changes in `OBJECT_MODIFIED_BY_DDL` JSON. |

## MVP Features Unlocked

1. **Org-wide cost attribution feed (FinOps core):** build a pipeline over `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` + `ORGANIZATION_USAGE.METERING_HISTORY` to power cross-account “top cost drivers” dashboards and anomaly detection.
2. **Native App: self-service “introspection without extra grants”:** inside the app, use newly-allowed `SHOW`/`DESCRIBE` + `INFORMATION_SCHEMA` access (owner’s rights context) to discover warehouses/DBs/schemas/objects to configure cost policies and diagnostics with fewer manual setup steps.
3. **Marketplace/listing governance pack:** use the new listing/share observability views + `ACCESS_HISTORY` updates to provide auditing (who changed what, when) and compliance reporting for data products and Native App distribution.

## Concrete Artifacts

### Draft: Org-wide hourly credits by account

```sql
-- Organization account context
SELECT
  start_time,
  account_name,
  credits_used
FROM snowflake.organization_usage.metering_history
WHERE start_time >= dateadd('day', -14, current_timestamp())
ORDER BY start_time DESC;
```

### Draft: Query-level cost attribution across the org

```sql
-- Schema/column names may differ; validate against the view reference.
SELECT
  start_time,
  account_name,
  warehouse_name,
  query_id,
  credits_attributed
FROM snowflake.organization_usage.query_attribution_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY credits_attributed DESC;
```

### Draft: Detect listing/share lifecycle changes (audit)

```sql
SELECT
  event_timestamp,
  user_name,
  object_modified_by_ddl
FROM snowflake.account_usage.access_history
WHERE event_timestamp >= dateadd('day', -30, current_timestamp())
  AND object_modified_by_ddl ILIKE '%"listing"%'
ORDER BY event_timestamp DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium views availability/entitlement may vary and rollout is gradual through Feb 9, 2026. | Feature may not work in some orgs immediately; need fallbacks. | Check presence/permissions in org account; document prerequisites. |
| Exact schema/columns for `QUERY_ATTRIBUTION_HISTORY` are not confirmed from release note alone. | Queries/dashboards might need adjustments. | Read the view reference + run `DESC VIEW` once available. |
| Owner’s rights contexts still restrict some session/user history functions. | Some “query history” style diagnostics may remain blocked inside Native Apps. | Confirm by testing allowed/blocked functions in an owner’s rights SP within an app. |

## Links & Citations

1. New ORGANIZATION_USAGE premium views (Feb 01, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. 10.3 release note: owner’s rights contexts allow `INFORMATION_SCHEMA`, `SHOW`, `DESCRIBE` (Feb 02–05, 2026): https://docs.snowflake.com/en/release-notes/2026/10_3
3. Listing/share observability GA (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Pull the view references for `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` and `METERING_HISTORY` and lock down column mappings for a first dashboard.
- Add a Native App “self-diagnose permissions & metadata access” screen that probes allowed `SHOW`/`DESCRIBE`/`INFORMATION_SCHEMA` operations under owner’s rights.
- Decide whether Marketplace/listing observability should be an MVP module or a later governance add-on.
