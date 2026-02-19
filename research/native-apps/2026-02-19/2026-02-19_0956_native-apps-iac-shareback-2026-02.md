# Research: Native Apps - 2026-02-19

**Time:** 0956 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Inter-app communication (IAC) is now available in Preview** (Feb 13, 2026). IAC allows a Snowflake Native App to request a connection to another installed app in the same consumer account and then call the other app’s procedures/functions (synchronous) or poll shared tables/views (asynchronous), mediated by app roles and consumer approval. 
2. IAC uses two new(ish) Snowflake Native App Framework concepts together:
   - **CONFIGURATION DEFINITION** of type `APPLICATION_NAME` to ask the consumer for the *actual installed name* of the target server app (since the consumer can rename apps at install time).
   - **APPLICATION SPECIFICATION** of type `CONNECTION` to request specific **server application roles**; the consumer must approve the connection.
3. **Shareback via app specifications is GA** (Feb 10, 2026). Native Apps can request consumer approval to share selected data back to the provider (or designated third parties) via **LISTING** specifications; this requires the app to create a **SHARE** + **LISTING** and then request targets via app specs (manifest v2 + privileges).
4. For shareback, the docs are explicit that:
   - `manifest_version: 2` is required for app specifications.
   - The app must request `CREATE SHARE` and `CREATE LISTING` privileges.
   - A `LISTING` specification is associated with **exactly one listing object**; you can’t create multiple app specs for the same listing.

## Snowflake Objects & Data Sources

| Object/View / SQL Object | Type | Source | Notes |
|---|---|---|---|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ... TYPE = APPLICATION_NAME` | Native Apps SQL | Docs | Used by a *client* app to request the installed name of a target server app for IAC. |
| `ALTER APPLICATION ... SET CONFIGURATION <name> VALUE = <server app name>` | Native Apps SQL | Docs | Used by consumer to provide the server app name back to the client app. |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION` | Native Apps SQL | Docs | Used by client app to request a connection + server app roles; consumer approves. |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <spec> SEQUENCE_NUMBER = <n>` | Native Apps SQL | Docs | Approval step for CONNECTION (and other spec types). |
| `SHOW APPROVED SPECIFICATIONS` | Native Apps SQL | Docs | Client apps can query and parse `definition` JSON (example in docs) to retrieve server app name at runtime (avoid rename issues). |
| `CREATE SHARE ...` | SQL | Docs | Required for shareback; share holds objects (generally from app-created DBs). |
| `CREATE EXTERNAL LISTING ... SHARE <share> ... PUBLISH=FALSE REVIEW=FALSE` | SQL | Docs | Listing object used for cross-account / cross-region distribution. |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = LISTING` with `TARGET_ACCOUNTS`, `LISTING`, optional `AUTO_FULFILLMENT_REFRESH_SCHEDULE` | Native Apps SQL | Docs | Shareback request workflow; consumer reviews/approves. |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“FinOps Enhancer” companion app pattern (IAC Preview):** allow our FinOps Native App (client) to connect to other installed apps (server) to enrich cost insights (e.g., ingest tags/ownership mappings, lineage, policy context) without hard-wiring integrations. The consumer explicitly selects the server app in Snowsight and approves requested server app roles.
2. **Provider-side telemetry / diagnostics (Shareback GA):** implement a LISTING shareback flow that lets consumers opt-in to share:
   - aggregated usage metrics (e.g., app feature usage counts),
   - anonymized performance stats,
   - compliance/audit artifacts
   back to our provider org account (or a support org). This can be used for proactive support and product analytics while staying in Snowflake’s governance model.
3. **In-app connection health + UX:** add a “Connections” page in our app that reads `SHOW APPROVED SPECIFICATIONS` and surfaces:
   - connection status (approved/pending/declined),
   - target server app name (from approved spec definition),
   - last successful call timestamp.

## Concrete Artifacts

### IAC handshake: minimal SQL skeleton (from docs, adapted)

```sql
-- Client app: request server app name (consumer can rename on install)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_server_app_role);

-- Consumer: view pending configuration requests
SHOW CONFIGURATIONS IN APPLICATION my_server_app_name;

-- Consumer: set the server app name into the client app config
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- Client app: request a CONNECTION specification to the server app
ALTER APPLICATION SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Consumer: approve connection request (sequence number required)
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### Shareback: minimal manifest + setup skeleton (from docs, adapted)

```yaml
# manifest.yml
manifest_version: 2

privileges:
  - CREATE SHARE:
      description: "Create a share for sending app telemetry back to provider"
  - CREATE LISTING:
      description: "Create a listing for cross-account/cross-region shareback"
```

```sql
-- setup script (runs on install/upgrade)
CREATE SHARE IF NOT EXISTS app_shareback_share;

-- Example grants (must be app-owned objects, typically in app-created DB)
-- GRANT USAGE ON DATABASE app_created_db TO SHARE app_shareback_share;
-- GRANT USAGE ON SCHEMA app_created_db.telemetry TO SHARE app_shareback_share;
-- GRANT SELECT ON TABLE app_created_db.telemetry.daily_metrics TO SHARE app_shareback_share;

CREATE EXTERNAL LISTING IF NOT EXISTS app_shareback_listing
  SHARE app_shareback_share
  AS $$
    title: "App Shareback"
    subtitle: "Optional telemetry/compliance shareback"
    description: "Share selected app-generated data with designated accounts"
    listing_terms:
      type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Shareback'
  DESCRIPTION = 'Share selected app telemetry/compliance artifacts with provider'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = app_shareback_listing;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| IAC is **Preview** | APIs/UX/contracts may change; avoid hard dependency for near-term GA roadmap | Track release notes + doc diffs; feature-flag IAC paths in product. |
| Role escalation concerns with IAC | Client app may gain indirect privileges (docs warn about external access etc.) | Implement explicit permissions review UI + docs; require consumer action. |
| Shareback requires app-owned objects + share/listing creation | Telemetry architecture must write to app-owned DB/schema designed for sharing | Prototype shareback dataset schema + grants; validate against Native Apps restrictions. |
| Cross-region shareback auto-fulfillment costs billed to consumer | Could create unexpected spend if refresh schedule too aggressive | Provide conservative default schedule + explicit cost warning in UI/documentation. |

## Links & Citations

1. Snowflake release note: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Snowflake docs: Inter-app Communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Snowflake release note: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Snowflake docs: Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Extract the exact DDL/contracts for `CONNECTION` specs (fields, sequence handling, callbacks) and map to our app’s installation + upgrade flow.
- Draft an internal design for a **shareback telemetry schema** (aggregate-first, privacy-preserving) + consumer-facing “what data is shared” copy.
- Consider a second note under `research/observability/` for Feb 2026 updates (Access History truncation indicators + Performance Explorer preview UX improvements) if we plan to lean into Snowsight-native workflows.
