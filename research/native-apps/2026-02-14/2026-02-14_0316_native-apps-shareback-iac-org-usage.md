# Research: Native Apps - 2026-02-14

**Time:** 03:16 UTC  
**Topic:** Snowflake Native App Framework (plus FinOps implications)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps now support **inter-app communication (IAC)** (Preview), enabling one native app (client) to securely connect to and call procedures/functions exposed by another native app (server) within the same consumer account. The connection uses **configuration definitions** + an **application specification** of type `CONNECTION`, and requires **consumer approval**. 
2. Snowflake Native Apps now support **Shareback** (General Availability): an app can request consumer permission to **share data back** to the provider or designated third parties via a governed mechanism using **shares + listings + LISTING app specifications**.
3. The **ORGANIZATION_USAGE** schema gained new **premium views** (rollout through Feb 9, 2026) that expose org-wide usage and enable **org-wide query cost attribution**.
4. Server release 10.3 expanded **owner’s rights contexts** (including Native Apps) to allow broader introspection: most `SHOW`/`DESCRIBE` commands and **INFORMATION_SCHEMA views/table functions** are now accessible (with exceptions for certain history functions).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` | View | `ORG_USAGE` (premium) | Hourly credit usage per account across the org. Latency up to ~24h. |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ORG_USAGE` (premium) | Attributes warehouse compute credits to specific queries across org accounts; excludes warehouse idle time; latency up to ~24h. |
| `CONFIGURATION DEFINITION` (Native App) | SQL object | Native App Framework | Used by client app to request the installed name of a server app (consumer can rename apps). |
| `APPLICATION SPECIFICATION` (`TYPE = CONNECTION`) | SQL object | Native App Framework | Used by client app to request a connection to server app; requires consumer approval; approval grants requested server app roles to client app. |
| `APPLICATION SPECIFICATION` (`TYPE = LISTING`) | SQL object | Native App Framework | Used by an app to request permission to share data via a specific listing + target accounts; requires consumer approval. |

## MVP Features Unlocked

1. **Provider telemetry shareback (GA)**: add an opt-in “Share telemetry/audit logs back to provider” flow using a `LISTING` app spec and a provider-owned target account. This enables real product analytics + compliance reporting without external egress.
2. **Modular “suite” pattern via IAC (Preview)**: split the FinOps app into smaller apps (e.g., *cost attribution engine*, *recommendations engine*, *governance pack*) and let them interoperate via `CONNECTION` specs; also enables third-party integrations (other native apps) inside the same account.
3. **Org-wide cost attribution dashboards**: if the org account has premium views enabled, build an “Org cost drill-down” experience using `ORGANIZATION_USAGE.METERING_HISTORY` + `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query cost) to identify top cost drivers across accounts.

## Concrete Artifacts

### Shareback (LISTING app specification) skeleton

```sql
-- manifest.yml (excerpt)
manifest_version: 2

privileges:
  - CREATE SHARE:
      description: "Create a share for telemetry/compliance data"
  - CREATE LISTING:
      description: "Create a listing for sharing telemetry/compliance data"

lifecycle_callbacks:
  specification_action: callbacks.on_spec_update
```

```sql
-- setup.sql (high-level sketch)
CREATE SHARE IF NOT EXISTS finops_telemetry_share;

-- grant only app-owned objects
GRANT USAGE ON DATABASE app_db TO SHARE finops_telemetry_share;
GRANT USAGE ON SCHEMA app_db.telemetry TO SHARE finops_telemetry_share;
GRANT SELECT ON TABLE app_db.telemetry.events TO SHARE finops_telemetry_share;

CREATE EXTERNAL LISTING IF NOT EXISTS finops_telemetry_listing
  SHARE finops_telemetry_share
  AS $$
    title: "FinOps App Telemetry"
    subtitle: "Opt-in telemetry/audit export"
    description: "Shares app telemetry and audit data with approved accounts"
    listing_terms:
      type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

ALTER APPLICATION SET SPECIFICATION telemetry_shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Opt-in to share telemetry/audit data for support and analytics'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = finops_telemetry_listing
  -- if cross-region, set AUTO_FULFILLMENT_REFRESH_SCHEDULE
  ;
```

### IAC (CONNECTION app specification) skeleton

```sql
-- client app: request the server app name first
ALTER APPLICATION
  SET CONFIGURATION DEFINITION finops_server_app_name
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for server app providing cost attribution APIs'
  APPLICATION_ROLES = (client_role);

-- after consumer sets VALUE with server app name, request connection
ALTER APPLICATION SET SPECIFICATION finops_server_connection
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for server app providing cost attribution APIs'
  SERVER_APPLICATION = <SERVER_APP_NAME>
  SERVER_APPLICATION_ROLES = (server_role);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is Preview and may change semantics/UX for approvals/config | Architecture built on it may need refactors | Track the IAC doc + release notes; test in at least one consumer account. |
| Shareback relies on listings/shares and has constraints (one LISTING spec per listing, app-owned data only) | Limits what can be shared back (no arbitrary consumer data) | Confirm app-owned-only requirement; design telemetry tables in app-owned DB. |
| ORG_USAGE premium views availability may vary / requires org account access | Org-wide dashboards may not work for many customers initially | Add feature gating and fallback to ACCOUNT_USAGE where possible. |
| Owner’s-rights introspection exceptions still block some history functions | Some “self-observability” features may remain limited in owner’s-rights | Validate exact blocked functions (e.g., QUERY_HISTORY*) in a native app context. |

## Links & Citations

1. Release note: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Native Apps doc: Inter-app Communication — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Native Apps doc: Request data sharing with app specifications — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Release note: New ORGANIZATION_USAGE premium views — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
6. ORG_USAGE view: METERING_HISTORY — https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history
7. ORG_USAGE view: QUERY_ATTRIBUTION_HISTORY — https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history
8. Server release 10.3 notes (owner’s rights introspection update) — https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Decide whether to adopt IAC now (Preview) or design for it as an optional integration path.
- Prototype Shareback telemetry: minimal schema + listing + LISTING spec approval flow.
- If Akhil has org account access: prototype org-wide cost attribution using ORG_USAGE premium views (with gating + latency handling).
