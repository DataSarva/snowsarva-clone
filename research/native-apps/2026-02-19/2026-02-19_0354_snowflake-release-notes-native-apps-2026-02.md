# Research: Native Apps - 2026-02-19

**Time:** 0354 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Inter-app Communication (IAC) is now available in Preview**: a Snowflake Native App can securely communicate with other apps in the *same consumer account* by exposing procedures/functions via interfaces controlled by app roles. Client/server apps can use synchronous calls or async patterns via tables/views. 
2. **Shareback is now General Availability**: a Native App can request consumer permission to share data back to the provider or designated third-party accounts via **LISTING** app specifications (requires `manifest_version: 2` + `CREATE SHARE` / `CREATE LISTING` privileges + app-created share/listing objects).
3. **Access History truncation behavior changed**: `ACCOUNT_USAGE.ACCESS_HISTORY` no longer drops over-large records; Snowflake truncates enough data to fit and adds indicators where values were truncated.

## Snowflake Objects & Data Sources

| Object/View / SQL Object | Type | Source | Notes |
|---|---|---|---|
| `ACCOUNT_USAGE.ACCESS_HISTORY` | View | Snowflake Docs (Release Notes) | Records may now be truncated instead of excluded; downstream parsers should handle truncation indicators. |
| `CONFIGURATION DEFINITION` (e.g., `TYPE = APPLICATION_NAME`) | SQL object | Snowflake Docs (IAC guide) | Used by client app to request the exact installed name of the server app (consumer may rename on install). |
| Application specification (`ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION`) | SQL object | Snowflake Docs (IAC guide) | Client app requests a connection + specific server application roles; consumer approves via Snowsight or SQL. |
| Application specification (`ALTER APPLICATION SET SPECIFICATION ... TYPE = LISTING`) | SQL object | Snowflake Docs (Shareback guide) | Used to request target accounts + (optional) cross-region auto-fulfillment schedule for a listing. |
| `CREATE SHARE` / `CREATE LISTING` | SQL commands | Snowflake Docs (Shareback guide) | Shareback requires the app to create a share + external listing (unpublished) and then request approval via LISTING spec. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Mission Control plugin” architecture (Native App + optional companion apps) using IAC (Preview)**
   - Make the FinOps app a *server* that exposes a small, stable interface (stored procedures/functions) for other apps to call.
   - Or make the FinOps app a *client* that can call “data quality / lineage / identity resolver” apps installed in the same account.
2. **GA Shareback-based telemetry channel (opt-in)**
   - Add a consumer-controlled “share telemetry back to provider” toggle that creates the share+listing and then requests approval via LISTING spec.
   - Use this for aggregated usage metrics, health signals, “cost anomaly fingerprints”, and support diagnostics.
3. **Hardening: access-history ingestion tolerant to truncation**
   - If we parse `ACCESS_HISTORY` for governance/cost attribution, update the pipeline to detect and safely handle truncation indicators.

## Concrete Artifacts

### IAC: handshake skeleton (client + consumer steps)

```sql
-- Client app setup: request the name of the target server app (consumer might have renamed it)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_server_app_role);

-- Consumer: find incoming requests on the server app
SHOW CONFIGURATIONS IN APPLICATION my_server_app_name;

-- Consumer: set the approved server app name into the client app configuration
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- Client app: request a connection + server app roles
ALTER APPLICATION SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Consumer (or server app) approves the connection request
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### Shareback (LISTING spec) skeleton

```yaml
# manifest.yml
manifest_version: 2
privileges:
  - CREATE SHARE:
      description: "Create a share for shareback telemetry"
  - CREATE LISTING:
      description: "Create a listing for shareback telemetry"
```

```sql
-- Setup script (provider-defined): create share + listing (must start unpublished)
CREATE SHARE IF NOT EXISTS telemetry_share;

-- grant app-created objects to share (examples)
-- GRANT USAGE ON DATABASE app_db TO SHARE telemetry_share;
-- GRANT USAGE ON SCHEMA app_db.telemetry TO SHARE telemetry_share;
-- GRANT SELECT ON TABLE app_db.telemetry.metrics TO SHARE telemetry_share;

CREATE EXTERNAL LISTING IF NOT EXISTS telemetry_listing
  SHARE telemetry_share
  AS $$
  title: "Telemetry Share"
  subtitle: "Opt-in diagnostics"
  description: "Share opt-in telemetry to provider for product improvement/support"
  listing_terms:
    type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

-- Request consumer permission for target accounts
ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Share opt-in telemetry with provider'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';

-- Post-approval validation
SHOW APPROVED SPECIFICATIONS IN APPLICATION;
DESC LISTING telemetry_listing;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| IAC is **Preview** (APIs/UX/permissions could change; rollout may be limited by region/edition). | Architecture may need refactor; feature gating required. | Track IAC guide changes + test in a dev consumer account. |
| Shareback via LISTING specs requires `manifest_version: 2` + automated privilege granting expectations. | Older manifests or existing apps may need a packaging upgrade/migration. | Validate upgrade path in an app package version bump. |
| `ACCESS_HISTORY` truncation indicators may break naive JSON parsing or downstream assumptions about completeness. | Governance/cost attribution pipelines might silently degrade. | Add truncation detection + warnings/metrics; confirm exact indicator fields in docs. |

## Links & Citations

1. Release notes overview (recent feature updates list): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 13, 2026 — Native Apps Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. IAC guide: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
4. Feb 10, 2026 — Native Apps Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
5. Shareback guide (LISTING specs): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
6. Feb 17, 2026 — Access history improvements: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-17-access-history
7. Feb 09, 2026 — Performance Explorer enhancements (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview

## Next Steps / Follow-ups

- Prototype a tiny “IAC server interface” in our app: 1-2 stored procedures (sync) + one async queue/table pattern.
- Design an opt-in shareback telemetry schema + data minimization policy; map to LISTING spec workflow.
- Update any access-history ingestion/parsing logic to tolerate truncation and emit warnings/metrics.
