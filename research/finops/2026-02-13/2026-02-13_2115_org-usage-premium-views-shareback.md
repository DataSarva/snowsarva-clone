# Research: FinOps - 2026-02-13

**Time:** 21:15 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced new **ORGANIZATION_USAGE premium views** (rolling out through Feb 9, 2026) that provide org-wide cost/usage visibility, including hourly metering per account and query-level cost attribution for warehouse queries.
2. Snowflake Native Apps now support **Shareback (GA)**, allowing providers to securely request permission from consumers to share data back to the provider or designated third parties (useful for telemetry, compliance reporting, analytics, preprocessing).
3. In server release **10.3 (Feb 02–05, 2026)**, **owner’s rights contexts** (incl. Native Apps and Streamlit) were expanded to allow most **SHOW/DESCRIBE** commands and access to **INFORMATION_SCHEMA** views/table functions, with some history-related exceptions.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| ORGANIZATION_USAGE.METERING_HISTORY | View | `ORG_USAGE` (organization account) | Returns **hourly credit usage** per account in the org (premium view). |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | View | `ORG_USAGE` (organization account) | Attributes **compute costs to specific queries** run on warehouses across the org (premium view). |
| INFORMATION_SCHEMA.* views + table functions | Views/TFs | `INFO_SCHEMA` | Now accessible from **owner’s rights contexts** (10.3), but history functions like QUERY_HISTORY* remain restricted. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide cost baseline + anomaly panel**: ingest ORGANIZATION_USAGE.METERING_HISTORY hourly, compute baselines per account/warehouse, and alert on spikes (per account and org total).
2. **Top query cost drivers across the org**: leverage ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY to surface “top N expensive queries” and recurring query patterns by service/team/account (actionable FinOps).
3. **Native App telemetry loop (provider analytics)**: use Native Apps **Shareback** so the app can request permission to send usage/health telemetry back to the provider (or a shared “analytics” account), enabling benchmark dashboards and proactive guidance.

## Concrete Artifacts

### Draft: org-wide query cost drivers (starting point)

```sql
-- NOTE: Column names may vary; validate in your org account once view is available.
-- Goal: identify top compute-cost-attributed queries over the last 7 days.

SELECT
  /* expected dimensions: account, warehouse, user, query_id, etc. */
  *
FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
QUALIFY 1=1;
```

### Draft: hourly metering rollup

```sql
SELECT
  *
FROM ORGANIZATION_USAGE.METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP());
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium views availability/entitlement varies by org/account | Feature may not be usable everywhere; app must gracefully degrade | Confirm availability in target org account; check docs for premium view enablement and required roles. |
| QUERY_ATTRIBUTION_HISTORY schema/columns differ from expected | Queries/ETL may break | Inspect `DESC VIEW` and sample rows once enabled; maintain a schema-mapping layer. |
| Shareback permission UX and governance constraints | Telemetry design may require explicit consumer consent flows | Prototype permission request flow; validate what can be shared back and in what format (docs for app specifications). |
| Owner’s rights introspection exceptions (history functions restricted) | Some observability queries may not work from app contexts | Confirm which INFORMATION_SCHEMA objects are allowed vs blocked; design around restricted history functions. |

## Links & Citations

1. Feb 01, 2026 — New ORGANIZATION_USAGE premium views (release note): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Feb 10, 2026 — Snowflake Native Apps: Shareback (GA) (release note): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. 10.3 Release Notes (Feb 02–05, 2026) — Owner’s rights contexts allow INFORMATION_SCHEMA/SHOW/DESCRIBE: https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Pull the reference pages for the two ORG_USAGE views (to capture exact columns + retention semantics) and update the SQL drafts with concrete field names.
- Review the “Request data sharing with app specifications” docs for Shareback and draft an end-to-end telemetry architecture (consumer consent → data contract → storage → analytics).
- Identify minimal “degrade gracefully” pathways if premium views are not available (fall back to ACCOUNT_USAGE where possible).
