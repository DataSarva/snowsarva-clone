# Research: FinOps - 2026-02-04

**Time:** 10:01 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added three new **ORGANIZATION_USAGE premium views** in the organization account: **METERING_HISTORY**, **NETWORK_POLICIES**, and **QUERY_ATTRIBUTION_HISTORY**.  
2. **ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY** is described as attributing **compute costs to specific queries run on warehouses** across the organization.  
3. Snowflake is rolling these new ORG premium views out gradually, targeting availability to all accounts by **Feb 9, 2026**.  
4. In server release **10.3 (preview; scheduled completion Feb 4)**, Snowflake expanded **owner’s rights contexts** (owner’s rights stored procedures, **Native Apps**, and **Streamlit**) to allow broader introspection via **INFORMATION_SCHEMA** plus most **SHOW** and **DESCRIBE** commands, with explicit exceptions for certain history functions.  
5. Snowflake Native Apps now support **consumer-controlled maintenance policies** (public preview) to delay upgrades until an allowed time window set by the consumer.  
6. Listing/share observability is now **GA**, adding Information Schema + Account Usage objects to inspect listings, shares, grants, and listing/share lifecycle DDL in ACCESS_HISTORY.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `ORGANIZATION_USAGE.METERING_HISTORY` | view (premium) | ORG_USAGE | Hourly credit usage per account (org-wide). New as of Feb 1, 2026. |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | view (premium) | ORG_USAGE | Attributes compute costs to specific queries run on warehouses (org-wide). New as of Feb 1, 2026. |
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | view (premium) | ORG_USAGE | Network policies across all accounts (org-wide). |
| Owner’s rights contexts → `INFORMATION_SCHEMA` access | behavior change | n/a | Applies to owner’s rights procs, Native Apps, Streamlit; some history functions remain restricted. |
| `INFORMATION_SCHEMA.LISTINGS` | view | INFO_SCHEMA | Real-time listings metadata (provider). |
| `INFORMATION_SCHEMA.SHARES` | view | INFO_SCHEMA | Shares metadata consistent with `SHOW SHARES` (provider + consumer). |
| `INFORMATION_SCHEMA.AVAILABLE_LISTINGS()` | table function | INFO_SCHEMA | Listings discoverable/available to consumers; supports filters. |
| `ACCOUNT_USAGE.LISTINGS` / `ACCOUNT_USAGE.SHARES` / `ACCOUNT_USAGE.GRANTS_TO_SHARES` | views | ACCOUNT_USAGE | Historical listing/share metadata (provider), up to ~3h latency; includes dropped objects (up to last year). |
| `ACCOUNT_USAGE.ACCESS_HISTORY` (enhanced) | view | ACCOUNT_USAGE | Now captures listing/share DDL + property changes in `OBJECT_MODIFIED_BY_DDL` JSON. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide chargeback/showback (query-level)**: use `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` to allocate warehouse compute cost to queries and roll up by (account, user, role, warehouse, tag/cost-center). This is the missing primitive for “true query cost attribution” across multi-account orgs.
2. **Cross-account burn-rate + anomaly alerts**: use `ORGANIZATION_USAGE.METERING_HISTORY` (hourly) to implement org-wide budget monitors, detect sudden per-account spikes, and correlate with query attribution to identify top drivers.
3. **Native App “self-diagnose” / “preflight” UX improvements**: with owner’s-rights contexts gaining `INFORMATION_SCHEMA` + `SHOW`/`DESCRIBE`, a Native App can provide richer environment validation (objects present, privileges, warehouse existence/config) without requiring the user to run manual SQL.

## Concrete Artifacts

### Org-wide compute attribution starter query (draft)

```sql
-- Draft (column names may differ; verify against docs for ORG_USAGE.QUERY_ATTRIBUTION_HISTORY)
-- Goal: query-level compute attribution rolled up per account + warehouse per day.

WITH q AS (
  SELECT
    account_name,
    warehouse_name,
    DATE_TRUNC('day', start_time) AS day,
    /* example fields */
    query_id,
    user_name,
    role_name,
    /* cost metric (verify actual column name) */
    credits_attributed
  FROM snowflake.organization_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
)
SELECT
  account_name,
  warehouse_name,
  day,
  SUM(credits_attributed) AS credits
FROM q
GROUP BY 1,2,3
ORDER BY day DESC, credits DESC;
```

### Native App upgrade “maintenance window” UX hook (concept)

- Provide an in-app admin page that documents how consumers can use:
  - `CREATE MAINTENANCE POLICY`
  - `ALTER MAINTENANCE POLICY`
- Suggest a default window that avoids business hours; link to official docs.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| ORG premium views require org account + specific privileges and may incur additional cost. | Limits who can use these features; impacts product packaging/tiers. | Confirm requirements and pricing for “premium views” + org account access. |
| Column names / semantics for `QUERY_ATTRIBUTION_HISTORY` may differ from assumptions (e.g., cost units, latency). | Wrong allocations and mistrust in FinOps outputs. | Pull schema from docs + test in a real org account when available. |
| Owner’s rights context still restricts some history functions (e.g., QUERY_HISTORY_BY_*). | Native App diagnostics might still be incomplete for historical troubleshooting. | Validate exactly which SHOW/DESCRIBE are allowed and which history functions remain blocked. |

## Links & Citations

1. New ORGANIZATION_USAGE premium views (Feb 01, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. 10.3 release notes preview (owner’s rights contexts allow INFORMATION_SCHEMA/SHOW/DESCRIBE): https://docs.snowflake.com/en/release-notes/2026/10_3
3. Consumer-controlled maintenance policies for Native Apps (Preview, Jan 23, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
4. Listing/share observability GA (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Pull the reference docs for `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` and capture exact columns + recommended rollups.
- Decide whether our FinOps Native App should: (a) require org account, (b) provide a degraded single-account mode, or (c) offer org-wide features as an “enterprise” tier.
- Update Native App “diagnostics” plan to exploit the expanded owner’s-rights introspection surface in 10.3.
