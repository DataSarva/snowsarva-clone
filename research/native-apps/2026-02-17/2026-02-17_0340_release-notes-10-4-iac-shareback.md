# Research: Native Apps - 2026-02-17

**Time:** 03:40 UTC  
**Topic:** Snowflake Native App Framework (+ org-level FinOps telemetry enablers)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (IAC)** is now available for Snowflake Native Apps in the same consumer account (Preview). It enables an “app-as-a-service” model where one app exposes callable procedures/functions to other apps via a governed connection workflow.  
2. IAC uses **CONFIGURATION DEFINITION** (to request the installed server app name) plus an **APPLICATION SPECIFICATION** of type **CONNECTION** (to request/approve role grants from server → client app). Approval triggers callbacks on both apps.
3. **Shareback** for Snowflake Native Apps is now **GA**: apps can request consumer permission to share data back to the provider (or third parties) using **LISTING**-type app specifications tied to an app-created **SHARE + LISTING**.
4. Snowflake added new **ORGANIZATION_USAGE premium views** in the org account to support org-wide FinOps visibility, including hourly credit usage by account (**METERING_HISTORY**) and query-level cost attribution (**QUERY_ATTRIBUTION_HISTORY**). (The release note states “three” new views, but the page text only enumerates two — treat the third as TBD until confirmed.)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| CONFIGURATION DEFINITION | SQL object | Native Apps (IAC) docs | Client app uses this to request server app name; consumer populates via `ALTER APPLICATION ... SET CONFIGURATION ... VALUE = <server_app_name>` |
| APPLICATION SPECIFICATION (TYPE=CONNECTION) | SQL object | Native Apps (IAC) docs | Used to request/approve app-to-app connection and server app role grants |
| APPLICATION SPECIFICATION (TYPE=LISTING) | SQL object | Native Apps (Shareback) docs | Requests target accounts + auto-fulfillment schedule; bound 1:1 to a listing |
| SHARE / LISTING | SQL objects | Native Apps (Shareback) docs | App creates these (requires `CREATE SHARE`, `CREATE LISTING` privileges in manifest v2) |
| ORGANIZATION_USAGE.METERING_HISTORY | View | Release note + SQL ref link | ORG_USAGE premium view in organization account; hourly credit usage per account |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | View | Release note + SQL ref link | ORG_USAGE premium view; attributes warehouse compute costs to queries |

## MVP Features Unlocked

1. **“Plugin” integrations between installed apps (Preview-gated):** Make our FinOps Native App usable as a *server app* that other internal apps can connect to for cost attribution / policy evaluation APIs, or as a *client app* that calls a governance/identity app for enrichment.
2. **First-class “Shareback Telemetry” pipeline (GA):** implement a provider-approved share/listing to receive usage telemetry, app health, and cost signals from consumers without custom data egress. This also unlocks compliance-friendly data exchange patterns.
3. **Org-wide cost attribution without per-account rollups:** use `ORGANIZATION_USAGE.METERING_HISTORY` + `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` in the org account to build centralized dashboards for chargeback/showback and “top expensive queries across the org”.

## Concrete Artifacts

### IAC handshake (minimal skeleton)

```sql
-- Step 1 (client): request target app name from consumer
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_client_app_role);

-- Consumer: discover pending config requests (run in server app)
SHOW CONFIGURATIONS IN APPLICATION my_server_app_name;

-- Consumer: set the server app name in client app config
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- Step 2 (client): request connection (app spec)
ALTER APPLICATION
  SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Step 3 (consumer): approve connection in server app
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### Shareback via LISTING app spec (manifest + setup highlights)

```yaml
# manifest.yml
manifest_version: 2
privileges:
  - CREATE SHARE:
      description: "Create a share for telemetry/compliance reporting"
  - CREATE LISTING:
      description: "Create a listing for cross-region data sharing"
```

```sql
-- setup.sql (high level)
CREATE SHARE IF NOT EXISTS telemetry_share;

CREATE EXTERNAL LISTING IF NOT EXISTS telemetry_listing
  SHARE telemetry_share
AS $$
  title: "Telemetry Share"
  subtitle: "Native App telemetry"
  description: "Governed telemetry shareback to provider"
  listing_terms:
    type: "OFFLINE"
$$
PUBLISH = FALSE
REVIEW = FALSE;

ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Share governed telemetry to provider for operations and compliance'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is Preview; availability/limits may vary by region/account | Could block relying on it for core app-to-app integration | Confirm feature flag/enablement + test in a dev account |
| Release note says 3 ORG_USAGE premium views but only 2 are listed on the page | We may miss a third useful cost/attribution view | Open the premium views doc + ORG_USAGE schema index; confirm the third view name |
| Shareback depends on listings/shares and consumer approval | Telemetry onboarding UX must be solid | Prototype “telemetry opt-in” flow in Snowsight + document requirements |

## Links & Citations

1. Release note: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Docs: Inter-app Communication — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Docs: Request data sharing with app specifications (LISTING) — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Release note: New ORGANIZATION_USAGE premium views — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views

## Next Steps / Follow-ups

- Confirm the “third” ORG_USAGE premium view name/content referenced in the Feb 1 release note.
- Draft an ADR for our FinOps Native App telemetry strategy: Shareback (LISTING spec) vs custom ingestion.
- Prototype a minimal “IAC server app” interface for cost attribution APIs (feature-flagged until IAC is GA).
