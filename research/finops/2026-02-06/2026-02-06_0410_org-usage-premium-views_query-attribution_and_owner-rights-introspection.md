# Research: FinOps - 2026-02-06

**Time:** 04:10 UTC  
**Topic:** Snowflake FinOps Cost Optimization (ORG_USAGE + cost attribution)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added three new **ORGANIZATION_USAGE premium views** in the **organization account**: `METERING_HISTORY`, `NETWORK_POLICIES`, and `QUERY_ATTRIBUTION_HISTORY`. (Rollout note: expected available to all accounts by **2026-02-09**.)
2. `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` is intended to **attribute compute costs to specific queries** run on warehouses across the org.
3. In server release **10.3 (Feb 02–05, 2026)** Snowflake updated **owner’s rights contexts** (owner’s-rights stored procedures, **Native Apps**, Streamlit) to allow broader introspection: most `SHOW`/`DESCRIBE` commands and access to `INFORMATION_SCHEMA` views + table functions (with some history-function restrictions).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.METERING_HISTORY` | View | `ORG_USAGE` (org account) | Returns **hourly credit usage per account** in the org. Useful for org-wide cost dashboards / chargeback.
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ORG_USAGE` (org account) | Computes / exposes **query-level cost attribution** across org accounts (warehouse compute). This is a key primitive for FinOps “top expensive queries” across accounts.
| `ORGANIZATION_USAGE.NETWORK_POLICIES` | View | `ORG_USAGE` (org account) | Governance/security visibility across accounts (not FinOps, but often adjacent reporting).
| `INFORMATION_SCHEMA` views & table functions (broader access) | Various | `INFO_SCHEMA` | Now accessible in owner’s-rights contexts (Native Apps / owner’s rights SPs), enabling richer self-diagnostics inside apps.

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide compute attribution dashboard (FinOps core):** Build a pipeline that reads `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (plus account identity mapping) to surface:
   - top queries by attributed credits ($)
   - top warehouses by query-attributed cost
   - app/team/project breakdown (when query tags are present)
2. **Cross-account chargeback with hourly rollups:** Use `ORGANIZATION_USAGE.METERING_HISTORY` for reliable hourly org-wide trends + anomaly detection (spikes per account).
3. **Native App self-diagnostics upgrade:** Inside an owner’s-rights Native App, add a “Diagnostics” page that runs `SHOW`/`DESCRIBE` and selected `INFORMATION_SCHEMA` queries to validate prerequisites and configuration (while explicitly avoiding restricted history functions).

## Concrete Artifacts

### SQL draft: org-wide top attributed queries (skeleton)

```sql
-- Org account context
-- NOTE: validate column names from the official view docs for QUERY_ATTRIBUTION_HISTORY.
-- This is a skeleton to show intended usage.

SELECT
  account_name,
  start_time,
  end_time,
  query_id,
  warehouse_name,
  query_tag,
  attributed_credits
FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY attributed_credits DESC
LIMIT 200;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium views may require additional entitlement / billing and are rolling out gradually through 2026-02-09. | Feature may not be available in all org accounts immediately. | Attempt `DESC VIEW ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` in org account; check docs + entitlement status.
| Column names/semantics for `QUERY_ATTRIBUTION_HISTORY` may differ from expectations (e.g., time grain, attribution methodology). | Incorrect dashboards / misleading cost attribution. | Pull view reference docs and test against known workloads; compare to warehouse metering totals.
| Owner’s-rights introspection is broader but still restricts certain history functions. | Native App diagnostics may fail if it queries restricted functions. | Add allowlist of allowed `INFORMATION_SCHEMA` objects; handle errors explicitly.

## Links & Citations

1. Snowflake Release Notes: **Feb 01, 2026 – New ORGANIZATION_USAGE premium views** (METERING_HISTORY, NETWORK_POLICIES, QUERY_ATTRIBUTION_HISTORY): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Snowflake Server Release Notes **10.3 (Feb 02–05, 2026)** – Owner’s rights contexts allow INFORMATION_SCHEMA, SHOW, DESCRIBE (impacts Native Apps): https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Pull the reference pages for `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` + `METERING_HISTORY` to confirm columns and data latency, then update the SQL draft into working queries.
- Decide how to map org-account results back to “business entity” (team/app) (likely via account metadata + query_tag conventions).
- For Native App diagnostics: catalog a safe set of `SHOW`/`DESCRIBE` commands to run and expected permissions in owner’s-rights contexts.
