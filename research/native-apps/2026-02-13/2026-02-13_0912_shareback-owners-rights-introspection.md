# Research: Native Apps - 2026-02-13

**Time:** 09:12 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “Shareback” is now GA (Feb 10, 2026).** Apps can request consumer permission to share data back to the provider (or designated third parties) via a governed exchange channel. This explicitly targets compliance reporting, telemetry/analytics, and preprocessing use cases. 
2. **Owner’s-rights execution contexts (including Native Apps) now permit substantially more introspection (10.3 release).** Most `SHOW`/`DESCRIBE` commands are now allowed, and `INFORMATION_SCHEMA` views/table functions are now accessible; however some session/user-history functions remain restricted (e.g., `QUERY_HISTORY*`, `LOGIN_HISTORY_BY_USER`).
3. **ORG-level FinOps signals expanded via new ORGANIZATION_USAGE premium views (Feb 1, 2026).** Snowflake added `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (compute cost attribution to queries on warehouses), plus `METERING_HISTORY` (hourly credit usage per account) and `NETWORK_POLICIES` (org-wide network policy visibility). Rollout targeted completion by Feb 9, 2026.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` (views + table functions) | INFO_SCHEMA | 10.3 release notes | Newly accessible from owner’s-rights contexts, with exceptions for some history functions. |
| `ORGANIZATION_USAGE.METERING_HISTORY` | ORG_USAGE (premium) | Feb 1 feature update | Hourly credit usage per account (org account). |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | ORG_USAGE (premium) | Feb 1 feature update | Attributes compute costs to specific queries run on warehouses across the org. |
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | ORG_USAGE (premium) | Feb 1 feature update | Org-wide view of network policies. |

## MVP Features Unlocked

1. **Native App telemetry “shareback” pipeline (opt-in):** Add an optional consumer consent flow to share back aggregated cost/performance metrics + app health signals to the provider account for fleet-level analytics.
2. **In-app “introspection-driven diagnostics” without elevated grants:** Use allowed `SHOW`/`DESCRIBE` + `INFORMATION_SCHEMA` access in owner’s-rights stored procedures to detect misconfigurations (missing objects, wrong privileges, wrong warehouse settings) and produce actionable remediation steps.
3. **Org-wide cost attribution dashboard:** If the customer has an org account + premium views enabled, ingest `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` to attribute warehouse spend to specific query patterns and surface “top cost drivers” across accounts.

## Concrete Artifacts

### Minimal approach: gated shareback tables

- Provider creates a destination schema/table for incoming telemetry.
- App requests shareback permission from consumer.
- App writes only **aggregated**, non-sensitive metrics (e.g., daily rollups, top-N) to reduce privacy risk.

### Candidate queries (sketch)

```sql
-- Example: identify the largest schema/table footprints using INFORMATION_SCHEMA
-- (exact views/functions may vary by database; validate on target objects)
SELECT table_schema, table_name
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE table_type = 'BASE TABLE'
ORDER BY created DESC
LIMIT 50;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Shareback consent mechanics + data routing details may require specific listing/app spec configuration. | Implementation time risk; potential listing changes. | Read/implement against “Request data sharing with app specifications” doc; prototype in a test listing. |
| Owner’s-rights access still restricts some history functions; we may not be able to get full query history from inside the app. | Limits in-app FinOps analysis depth; may need consumer-provided views or external connectors. | Verify which `INFORMATION_SCHEMA` table functions work in owner’s-rights, and document fallbacks. |
| ORG_USAGE premium views require org account + entitlement/rollout; not all customers will have them. | Feature gating needed; UX must degrade gracefully. | Detect availability at runtime (probe view existence/privileges) and hide org-wide features if unavailable. |

## Links & Citations

1. Snowflake release notes index (for context + additional items): https://docs.snowflake.com/en/release-notes/new-features
2. Native Apps Shareback GA (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. “Request data sharing with app specifications” (shareback details): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
4. 10.3 Release Notes (owner’s-rights introspection changes): https://docs.snowflake.com/en/release-notes/2026/10_3
5. New ORGANIZATION_USAGE premium views (Feb 1, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
6. `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` reference: https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history

## Next Steps / Follow-ups

- Prototype shareback-enabled telemetry flow in a dev listing; decide on the minimal metric set + privacy posture.
- Add a capability probe to the app: detect if owner’s-rights can access required `INFORMATION_SCHEMA` objects; generate a diagnostics report.
- For FinOps: validate `QUERY_ATTRIBUTION_HISTORY` shape and retention, then map it into a “top cost drivers” model for the app.
