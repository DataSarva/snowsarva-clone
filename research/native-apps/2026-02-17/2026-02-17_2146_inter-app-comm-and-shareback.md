# Research: Native Apps - 2026-02-17

**Time:** 21:46 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps now support **Inter-app Communication (IAC)** (Preview), enabling one native app (client) to securely call procedures/functions exposed by another native app (server) in the **same consumer account** via an approval/handshake workflow. 
2. IAC uses (a) a **CONFIGURATION DEFINITION** (TYPE=APPLICATION_NAME) to resolve the server app’s installed name (since consumers can rename apps), and (b) an **APPLICATION SPECIFICATION** (TYPE=CONNECTION) to request a connection/roles, which the consumer must approve.
3. Snowflake Native Apps **Shareback** is now **GA**: apps can request consumer permission to share data back to the provider (or third parties) via **LISTING** application specifications, creating app-owned shares/listings and asking the consumer to approve target accounts and (for cross-region) auto-fulfillment schedules.
4. **ACCESS_HISTORY (ACCOUNT_USAGE)** behavior changed: records that were previously excluded for being too large are now **truncated to fit** and include indicators of truncation; this improves completeness of audit/lineage monitoring.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION` | SQL command | Docs | Used by client app to request server app name (TYPE=APPLICATION_NAME). |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Docs | Used by consumer to see pending configuration requests. |
| `ALTER APPLICATION ... SET CONFIGURATION ... VALUE = ...` | SQL command | Docs | Consumer sets resolved server app name into client app configuration definition. |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE=CONNECTION` | SQL command | Docs | Client requests connection to server app + requested server application roles. |
| `ALTER APPLICATION ... APPROVE SPECIFICATION ... SEQUENCE_NUMBER = <n>` | SQL command | Docs | Consumer approves connection/listing specifications. |
| `SHOW APPROVED SPECIFICATIONS` | SQL command | Docs | Client can fetch approved spec definition (e.g., SERVER_APPLICATION) at runtime to be robust to rename. |
| `CREATE SHARE` | SQL command | Docs | Shareback workflow: app creates share and grants app-owned objects. |
| `CREATE EXTERNAL LISTING` | SQL command | Docs | Shareback workflow: app creates listing (PUBLISH=FALSE, REVIEW=FALSE required initially). |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE=LISTING` | SQL command | Docs | Shareback permissioning: requests TARGET_ACCOUNTS + LISTING + optional AUTO_FULFILLMENT_REFRESH_SCHEDULE. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | ACCOUNT_USAGE | Truncation indicators now appear when oversized records are truncated instead of being dropped. |

## MVP Features Unlocked

1. **“FinOps Companion” IAC server app**: ship a small native app exposing procedures/functions that other installed apps can call for shared capabilities (e.g., normalize warehouse sizing recommendations, query-cost heuristics). Use app roles to gate functions per app.
2. **Provider telemetry via Shareback (LISTING spec)**: implement an opt-in telemetry/audit dataset (e.g., aggregated usage metrics, feature flags) shared back to provider account(s) using listing app specs; include clear data dictionary + consumer-facing disclosures.
3. **Governance completeness check**: in our FinOps app, add a diagnostics panel that queries ACCESS_HISTORY and flags presence of truncation indicators (and volume), so customers know if they’re relying on truncated audit payloads.

## Concrete Artifacts

### IAC: minimal handshake SQL (client + consumer + server)

```sql
-- CLIENT APP (setup): ask consumer to identify server app
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  APPLICATION_ROLES = (my_server_app_role);

-- CONSUMER: discover pending config requests (run against the server app)
SHOW CONFIGURATIONS IN APPLICATION my_server_app_name;

-- CONSUMER: set the server name into the client app configuration
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- CLIENT APP: request connection (CONNECTION spec)
ALTER APPLICATION SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- CONSUMER (in server app): approve spec
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### Shareback (LISTING spec): minimal pattern

```sql
-- APP (setup/upgrade): create share + listing (must be app-owned objects)
CREATE SHARE IF NOT EXISTS compliance_share;

CREATE EXTERNAL LISTING IF NOT EXISTS compliance_listing
  SHARE compliance_share
  AS $$
  title: "Compliance Data Share"
  subtitle: "Regulatory compliance reporting data"
  description: "Share compliance and audit data with authorized accounts"
  listing_terms:
    type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

-- APP: request consumer permission to share to target accounts
ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Compliance Data Sharing'
  DESCRIPTION = 'Share compliance data with provider for regulatory reporting'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount,AuditorOrg.AuditorAccount'
  LISTING = compliance_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is Preview; interfaces/callback semantics may change. | Potential rework for early adopters. | Track release notes for IAC GA + callback reference changes. |
| IAC can indirectly elevate privileges if server app has powerful capabilities (e.g., external access). | Security review needed; customers may block approval. | Build a “capability disclosure” section + recommended admin checks (SHOW PRIVILEGES/REFERENCES/GRANTS). |
| Shareback requires app-owned data objects and listing constraints (manifest fields limited; new listings must start unpublished). | Limits what can be shared and how we present it. | Validate with a toy app package + install/upgrade flow; confirm constraints in practice. |
| ACCESS_HISTORY truncation indicators need concrete detection logic (exact sentinel values/fields). | Diagnostics could be noisy or wrong. | Query docs for truncation notes + test in an account with large records. |

## Links & Citations

1. Release note: IAC (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. IAC docs — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Shareback docs (LISTING app specs) — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Release note: Access history improvements — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-17-access-history
6. ACCESS_HISTORY view docs — https://docs.snowflake.com/en/sql-reference/account-usage/access_history

## Next Steps / Follow-ups

- Prototype a minimal two-app IAC demo: (a) “server” app exposes 1-2 stable procedures, (b) “client” app calls them and stores results.
- Draft a “Shareback telemetry data contract” (tables, retention, anonymization) suitable for Marketplace review + customer security review.
- Add an internal checklist for customers: what to inspect before approving CONNECTION/LISTING specs.
