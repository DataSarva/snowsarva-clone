# Research: Native Apps - 2026-02-14

**Time:** 15:21 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (IAC) is now available in Preview** and allows one Snowflake Native App to securely communicate with other apps in the same consumer account via exposed functions/procedures, with app-role–controlled access and support for synchronous and asynchronous patterns.  
2. **Shareback is now GA**: a Snowflake Native App can request consumer permission to share data back to the provider or designated third-party accounts via listings + shares using app specifications (LISTING type).  
3. **Owner’s-rights contexts expanded** (including Native Apps): most **SHOW**/**DESCRIBE** commands and **INFORMATION_SCHEMA** views/table functions are now permitted, with explicit exceptions for some history functions (e.g., QUERY_HISTORY* and LOGIN_HISTORY_BY_USER).  

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App object | IAC doc | Used by client app to request the installed name of the server app (consumer sets value). |
| `APPLICATION SPECIFICATION` (`TYPE = CONNECTION`) | Native App object | IAC doc | Used to request a connection + server app roles; consumer approves (SQL or Snowsight). |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SHOW command | IAC doc | Consumer inspects incoming config requests. |
| `SHOW APPROVED SPECIFICATIONS IN APPLICATION` | SHOW command | IAC doc | Client app can query approved specs to discover runtime server app name. |
| `APPLICATION SPECIFICATION` (`TYPE = LISTING`) | Native App object | Shareback doc | Used to request permission to share data to provider/third parties. |
| `CREATE SHARE` | SQL | Shareback doc | App creates share(s) for app-owned DB objects. |
| `CREATE EXTERNAL LISTING` | SQL | Shareback doc | App creates listing attached to share; must start unpublished (`PUBLISH=FALSE`, `REVIEW=FALSE`). |
| `DESC LISTING <name>` | SQL | Shareback doc | Used to validate listing configuration after approval. |
| `INFORMATION_SCHEMA` views/table functions | INFO_SCHEMA | 10.3 release notes | Newly allowed in owner’s-rights contexts for Native Apps (exceptions apply). |

## MVP Features Unlocked

1. **Composable “FinOps suite” architecture (multi-app) using IAC (Preview):**
   - Ship a small “Telemetry/Cost Kernel” app that exposes stable procedures/functions (e.g., normalize warehouse/query tags, emit cost signals, evaluate anomaly rules). Other apps (e.g., “Policy/Guardrails UI”, “Optimization advisor”) connect as IAC clients.
2. **Opt-in provider telemetry via Shareback (GA):**
   - Add an optional, consumer-approved “share usage metrics back to provider” flow using LISTING app specifications (for: feature adoption metrics, app health, anonymized cost deltas). This is a clean, governed channel vs. bespoke outbound networking.
3. **Richer in-app introspection (10.3):**
   - Use newly-allowed SHOW/DESCRIBE + INFORMATION_SCHEMA access inside owner’s-rights stored procedures to drive *on-account discovery* (e.g., inventory warehouses/tasks/pipes, validate required objects) without requiring users to run manual SQL.

## Concrete Artifacts

### Sketch: IAC handshake (client ↔ server)

```sql
-- CLIENT setup: request server app name (consumer will fill)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_client_app_role);

-- CLIENT: after server name set, request connection + server roles
ALTER APPLICATION
  SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);
```

### Sketch: Shareback via LISTING app specification

```sql
-- App-owned share + listing
CREATE SHARE IF NOT EXISTS telemetry_share;
CREATE EXTERNAL LISTING IF NOT EXISTS telemetry_listing
  SHARE telemetry_share
  AS $$
    title: "FinOps App Telemetry"
    subtitle: "Opt-in usage + diagnostics"
    description: "Opt-in governed telemetry shareback"
    listing_terms:
      type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

-- Request consumer approval to share to provider account(s)
ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Opt-in: share diagnostic + usage metrics to provider for support and product improvement'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is **Preview** | Breaking changes / limited availability; may not be on all accounts | Confirm feature availability in target regions/accounts; validate required manifest versions/capabilities. |
| Shareback requires listing/share creation privileges and app-owned DB objects | Architecture needs app-owned storage for telemetry tables | Prototype minimal shareback dataset; verify consumer approval UX in Snowsight. |
| Owner’s-rights access still blocks certain history functions | Some FinOps insights may still need ACCOUNT_USAGE/ORG_USAGE access patterns outside owner’s rights | Validate exactly which views/tables are accessible in owner’s-rights stored procs in practice. |

## Links & Citations

1. Snowflake release note: **Inter-App Communication (Preview)** (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Snowflake doc: **Inter-app Communication**: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Snowflake release note: **Shareback (GA)** (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Snowflake doc: **Request data sharing with app specifications** (LISTING): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Snowflake server release notes **10.3** (Owner’s-rights contexts update): https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Map our FinOps Native App architecture into (a) single-app baseline, (b) multi-app suite using IAC (client/server roles + approvals).
- Decide what “telemetry shareback” dataset we would actually want (minimal + privacy-safe) and draft a schema + retention plan.
- Validate (hands-on) which SHOW/DESCRIBE and INFO_SCHEMA queries are now permitted inside owner’s-rights stored procedures in a Native App context.
