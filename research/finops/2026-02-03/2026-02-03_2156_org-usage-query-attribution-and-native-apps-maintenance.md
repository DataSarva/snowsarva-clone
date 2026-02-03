# FinOps Research Note — ORG_USAGE premium views: QUERY_ATTRIBUTION_HISTORY (and related updates)

- **When (UTC):** 2026-02-03 21:56
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** These updates add first-class, Snowflake-provided org-wide metering + query-to-cost attribution and improve share/listing observability—unlocking stronger “blame/chargeback” and governance features a FinOps Native App can productize with fewer fragile joins.

## Accurate takeaways
- Snowflake added **three new ORGANIZATION_USAGE *premium views*** (rolling out through **Feb 9, 2026**) in the **organization account**:
  - **ORGANIZATION_USAGE.METERING_HISTORY** — hourly credit usage per account.
  - **ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY** — attributes compute costs to specific queries run on warehouses across the org.
  - **ORGANIZATION_USAGE.NETWORK_POLICIES** — inventory of network policies across all accounts.
- Snowflake also released **Listing + Share observability (GA)** with new **INFORMATION_SCHEMA** views/table functions and new **ACCOUNT_USAGE** views, plus enhancements to **ACCOUNT_USAGE.ACCESS_HISTORY** to capture listing/share DDL lifecycle events.
- For Native Apps specifically (separate release note): **consumer-controlled maintenance policies** are in **public preview**, letting consumers delay/permit app upgrades within defined windows via **CREATE/ALTER MAINTENANCE POLICY**.

## Snowflake objects & data sources (verify in target account)
- **ORG_USAGE (organization account, premium views):**
  - `ORGANIZATION_USAGE.METERING_HISTORY` (hourly credits by account)
  - `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (query-level attribution to compute cost)
  - `ORGANIZATION_USAGE.NETWORK_POLICIES` (policy inventory)
- **ACCOUNT_USAGE (account-level historical, ~<=3h latency):**
  - `ACCOUNT_USAGE.LISTINGS`
  - `ACCOUNT_USAGE.SHARES`
  - `ACCOUNT_USAGE.GRANTS_TO_SHARES`
  - `ACCOUNT_USAGE.ACCESS_HISTORY` — now includes listing/share DDL ops and property deltas in `OBJECT_MODIFIED_BY_DDL` JSON.
- **INFORMATION_SCHEMA (real-time, role-scoped):**
  - `<db>.INFORMATION_SCHEMA.LISTINGS`
  - `<db>.INFORMATION_SCHEMA.SHARES`
  - `TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS(...))`

## MVP features unlocked (PR-sized)
1) **Org-wide “Top Cost Drivers by Query”**: build a page that surfaces top queries by attributed credits/dollars across all org accounts using `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY`, with drill-through to warehouse/account/user tags.
2) **Chargeback / showback v1**: export org-wide hourly metering (`ORGANIZATION_USAGE.METERING_HISTORY`) to a normalized internal table (or app-managed dataset) with allocations by account + business unit.
3) **Share/listing governance audit**: detect and alert on listing/share lifecycle changes by ingesting `ACCOUNT_USAGE.ACCESS_HISTORY` deltas for listing/share DDL and correlating to `ACCOUNT_USAGE.SHARES` / `GRANTS_TO_SHARES`.

## Heuristics / detection logic (v1)
- Cost driver: rank `(account, warehouse, query_hash/query_id)` by `attributed_credits` (exact column names TBD—confirm in view docs) over `last_7_days`, flag top N and large deltas vs trailing avg.
- Chargeback: map accounts → cost center via config; allocate hourly credits from `ORG_USAGE.METERING_HISTORY`.
- Governance: whenever `ACCESS_HISTORY.OBJECT_MODIFIED_BY_DDL` indicates CREATE/ALTER/DROP for listings/shares, emit an event + capture who/when + before/after properties.

## Security/RBAC notes
- These are **ORG_USAGE premium views** in the **organization account**; access will depend on org account roles and premium-view entitlements. App should gracefully degrade when not present.
- INFORMATION_SCHEMA views are **role-scoped** and don’t include deleted objects; ACCOUNT_USAGE includes dropped objects (within retention windows).

## Risks / assumptions
- Column names/semantics for `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` need validation in-docs before implementation.
- “Premium views” may require explicit enablement/contracting; assume not available everywhere.
- Orgs without an organization account (or without permissions) won’t have these views—need fallback to account-level `ACCOUNT_USAGE` based logic.

## Links / references
- New ORG_USAGE premium views (Feb 01, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
- Listing/share observability GA (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga
- Native Apps maintenance policies (Preview) (Jan 23, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
