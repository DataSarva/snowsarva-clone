# Research: Native Apps - 2026-02-14

**Time:** 21:23 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced **Inter-App Communication (IAC)** for Snowflake Native Apps (Preview, announced Feb 13 2026), enabling apps in the **same consumer account** to securely communicate and share/merge data via functions/procedures and app roles. 
2. IAC uses a **client/server app** model with a consumer-mediated “handshake”:
   - client requests the server app name via **CONFIGURATION DEFINITION** (type `APPLICATION_NAME`),
   - client requests access via an **APPLICATION SPECIFICATION** (type `CONNECTION`),
   - consumer approves the specification; Snowflake grants the requested **server app roles** to the client app.
3. IAC supports **synchronous** (direct function/procedure calls) and **asynchronous** (polling result tables/views) interaction patterns.
4. When a connection is approved, Snowflake **also grants USAGE on the client app to the server app**, allowing the server to know which client apps are connected.
5. Snowflake introduced **Shareback** for Snowflake Native Apps (GA, announced Feb 10 2026): apps can request consumer permission to **share data back** to the provider or designated third-party Snowflake accounts through **shares + external listings**, governed by **LISTING app specifications**.
6. LISTING app specifications require **`manifest_version: 2`** and request privileges like **`CREATE SHARE`** and **`CREATE LISTING`**; consumer approval automatically configures target accounts and (for cross-region) listing auto-fulfillment refresh schedule.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| CONFIGURATION DEFINITION | SQL object | Native App Framework | Client uses `ALTER APPLICATION SET CONFIGURATION DEFINITION ... TYPE=APPLICATION_NAME` to request server app name. |
| APPLICATION SPECIFICATION (TYPE=CONNECTION) | SQL object | Native App Framework | Client requests connection to server app (server roles) via `ALTER APPLICATION SET SPECIFICATION ... TYPE=CONNECTION`. |
| APPLICATION SPECIFICATION (TYPE=LISTING) | SQL object | Native App Framework | Used for Shareback: requests target accounts + listing association (`TARGET_ACCOUNTS`, `LISTING`, optional `AUTO_FULFILLMENT_REFRESH_SCHEDULE`). |
| SHARE | SQL object | Secure Data Sharing | App creates a share containing app-owned DB objects to share back. |
| EXTERNAL LISTING | SQL object | Marketplace/Listings | App creates an unpublished external listing attached to the share; consumer approval controls target accounts + refresh schedule. |
| SHOW CONFIGURATIONS IN APPLICATION | Command/result set | Native App Framework | Consumer discovers pending configuration definition requests (e.g., to set server app name). |
| SHOW APPROVED SPECIFICATIONS IN APPLICATION | Command/result set | Native App Framework | Used to retrieve approved specs; doc example uses `SHOW APPROVED SPECIFICATIONS ->> SELECT ...` to read server app name from spec definition JSON. |

## MVP Features Unlocked

1. **Composable “FinOps Agent” native app**: ship a “server” app that exposes cost/optimization procedures (e.g., anomaly scoring, query triage) and allow other internal apps (observability, governance) to call it via IAC.
2. **Provider telemetry shareback (opt-in)**: implement shareback to stream anonymized/aggregated usage metrics and diagnostic artifacts back to the provider account for support + product analytics, with clear spec descriptions and a least-privilege listing/share.
3. **Cross-app capability discovery + hardening**: add an admin UI/diagnostics routine that enumerates:
   - pending/approved specs,
   - server roles granted to client apps,
   - external access implications (per doc security considerations),
   to help consumers evaluate privilege elevation before approval.

## Concrete Artifacts

### IAC handshake skeleton (client setup)

```sql
-- Step 1: request server app name (consumer fills this in)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  APPLICATION_ROLES = (my_server_app_role);

-- Step 2: once configuration is set, request connection via specification
ALTER APPLICATION SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);
```

### Shareback skeleton (provider app setup)

```sql
-- Requires manifest_version: 2 and privileges CREATE SHARE / CREATE LISTING

CREATE SHARE IF NOT EXISTS compliance_share;
GRANT USAGE ON DATABASE app_created_db TO SHARE compliance_share;
GRANT USAGE ON SCHEMA app_created_db.reporting TO SHARE compliance_share;
GRANT SELECT ON TABLE app_created_db.reporting.metrics TO SHARE compliance_share;

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
| IAC is Preview and may change (syntax, callbacks, UX). | App-to-app integrations may break or need rework. | Track release notes + doc diffs; avoid hard dependencies until GA. |
| Privilege elevation via IAC (e.g., indirect access to server app’s external access). | Security risk; consumers may reject connections. | Provide clear connection descriptions; add admin diagnostics + least-privilege server roles. |
| Shareback requires app-created DB objects only (per doc), plus careful listing/share integrity. | Provider telemetry designs must use app-owned objects and protect from consumer edits. | Design immutable pipelines, signatures, and validation; document shared schema + data minimization. |
| Cross-region auto-fulfillment schedule decisions can impose consumer costs. | FinOps-sensitive users may be unhappy with aggressive refresh. | Default conservative refresh; make it configurable with clear cost guidance. |

## Links & Citations

1. Release note: Feb 13, 2026 — Native Apps Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Doc: Inter-app Communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Feb 10, 2026 — Native Apps Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Doc: Request data sharing with app specifications (LISTING / shareback): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Decide whether our FinOps Native App should be an **IAC server** (providing services to other apps) or **IAC client** (consuming governance/identity services) in the MVP.
- Draft an **ADR** for “Inter-app capability model” (app roles, least-privilege interfaces, sync vs async patterns).
- Prototype **opt-in shareback** data model for telemetry: what tables, retention, anonymization; verify constraints for app-owned objects.
