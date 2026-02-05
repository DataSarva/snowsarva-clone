# Research: FinOps - 2026-02-05

**Time:** 10:06 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced new **ORGANIZATION_USAGE premium views** in the organization account, including **QUERY_ATTRIBUTION_HISTORY**, which “attributes compute costs to specific queries run on warehouses in your organization.”
2. Snowflake introduced **ORGANIZATION_USAGE.METERING_HISTORY** (hourly credit usage per account in the org) and **ORGANIZATION_USAGE.NETWORK_POLICIES** (network policy inventory across all accounts).
3. Snowflake expanded the permissions in **owner’s rights contexts** (explicitly including **Native Apps**) to allow broader introspection: most **SHOW/DESCRIBE** commands and access to **INFORMATION_SCHEMA views/table functions**, with some history functions still restricted.
4. Snowflake GA’d **listing/share observability** via new INFORMATION_SCHEMA views / table functions and new ACCOUNT_USAGE views, plus ACCESS_HISTORY enhancements for listings/shares DDL auditing.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | ORG_USAGE (premium) | Release notes (Feb 01, 2026) | Key FinOps primitive: query→cost attribution across org accounts (warehouse queries). Availability rolling out through Feb 9, 2026. |
| ORGANIZATION_USAGE.METERING_HISTORY | ORG_USAGE (premium) | Release notes (Feb 01, 2026) | Hourly credit usage per account (org-wide). |
| ORGANIZATION_USAGE.NETWORK_POLICIES | ORG_USAGE (premium) | Release notes (Feb 01, 2026) | Governance inventory angle; also useful for compliance dashboards. |
| <db>.INFORMATION_SCHEMA.LISTINGS | INFO_SCHEMA | Release notes (Feb 02, 2026) | Real-time view for providers; no latency; doesn’t capture deleted objects. |
| <db>.INFORMATION_SCHEMA.SHARES | INFO_SCHEMA | Release notes (Feb 02, 2026) | Aligns with SHOW SHARES; includes inbound + outbound shares. |
| <db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS() | INFO_SCHEMA (table function) | Release notes (Feb 02, 2026) | Consumer-side discoverability; supports filters (imported/org/direct). |
| ACCOUNT_USAGE.LISTINGS / SHARES / GRANTS_TO_SHARES | ACCOUNT_USAGE | Release notes (Feb 02, 2026) | Historical (≤3h latency) provider-side objects & grants. |
| ACCOUNT_USAGE.ACCESS_HISTORY (enhanced) | ACCOUNT_USAGE | Release notes (Feb 02, 2026) | Now captures listing/share DDL and detailed property changes in OBJECT_MODIFIED_BY_DDL JSON. |
| Owner’s rights context introspection (Native Apps) | Platform behavior change | Release notes (10.3 preview) | Allows INFO_SCHEMA + most SHOW/DESCRIBE; still blocks QUERY_HISTORY*, LOGIN_HISTORY_BY_USER. |

## MVP Features Unlocked

1. **Org-wide Query Cost Attribution dashboard** (FinOps Native App): roll up QUERY_ATTRIBUTION_HISTORY by account/warehouse/user/role/tag and surface “top expensive queries” + “cost by business unit” (if query tags are enforced).
2. **Chargeback/Showback v1**: combine ORG_USAGE.METERING_HISTORY (account hourly credits) with QUERY_ATTRIBUTION_HISTORY (query-level) to allocate shared warehouse spend.
3. **Native App “introspection mode” improvements**: leverage expanded owner’s rights context permissions to safely run INFO_SCHEMA queries and SHOW/DESCRIBE from within the app for better diagnostics (e.g., warehouse config, grants inventory), while staying clear of restricted history functions.

## Concrete Artifacts

### Example: top attributed query costs (shape only; validate column names)

```sql
-- NOTE: column names in QUERY_ATTRIBUTION_HISTORY should be validated in docs.
-- Goal: identify top cost drivers across org.
SELECT
  account_name,
  warehouse_name,
  user_name,
  role_name,
  query_tag,
  SUM(credits_attributed) AS credits
FROM organization_usage.query_attribution_history
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5
ORDER BY credits DESC
LIMIT 100;
```

### Example: org-wide hourly metering

```sql
SELECT
  account_name,
  start_time,
  credits_used
FROM organization_usage.metering_history
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| QUERY_ATTRIBUTION_HISTORY column names / semantics may differ from assumed SQL above | Could break queries / mis-attribute spend | Confirm via official view docs page for ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY before implementing. |
| These are **premium views** and are rolled out gradually | App features may not work for all customers immediately | Detect availability at runtime; degrade gracefully (feature flags + UI messaging). |
| Owner’s rights context still restricts certain history functions | Limits in-app deep query history analytics | Rely on permitted views; request explicit grants or alternative telemetry paths when needed. |

## Links & Citations

1. Snowflake release notes (New features / recent feature updates): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 01, 2026: New ORGANIZATION_USAGE premium views: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
3. 10.3 Release Notes (Preview) – Owner’s rights contexts introspection expansion: https://docs.snowflake.com/en/release-notes/2026/10_3
4. Feb 02, 2026: Support for listing and share observability (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Pull the 3 ORG_USAGE view reference pages and record **exact column sets** + example queries for:
  - ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
  - ORGANIZATION_USAGE.METERING_HISTORY
  - ORGANIZATION_USAGE.NETWORK_POLICIES
- Define a minimal **FinOps data model** for cost attribution (account, warehouse, principal, query_tag, time bucket) and map to UI widgets.
- For Native App: prototype a “safe introspection” module using INFORMATION_SCHEMA + SHOW/DESCRIBE patterns that work under owner’s rights context.
