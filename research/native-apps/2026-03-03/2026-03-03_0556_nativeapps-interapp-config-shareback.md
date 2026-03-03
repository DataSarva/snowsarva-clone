# Research: Native Apps - 2026-03-03

**Time:** 05:56 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps now support **inter-app communication (IAC)** in *Preview*, enabling one app (client) to securely call functions/procedures exposed by another app (server) in the **same consumer account**. (Release note + IAC doc)
2. Snowflake Native Apps now support **application configuration** in *Preview*, letting an app request **key/value input from the consumer** (types: `APPLICATION_NAME`, `STRING`). Configuration values can be marked **`SENSITIVE=TRUE`** (STRING only) to redact values from query history and omit them from SHOW/DESCRIBE and usage views. (Release note + config doc)
3. Snowflake Native Apps now support **Shareback** in **GA**, allowing an app to request consumer permission to share data back to the provider (or third parties) using **LISTING app specifications** + secure data sharing constructs (shares + listings). (Release note + listing spec doc)
4. IAC uses a handshake workflow: the client app requests the server app name via a configuration definition (`TYPE = APPLICATION_NAME`), then requests/obtains a connection via an **application specification** (`TYPE = CONNECTION`) that the consumer approves (SQL or Snowsight). (IAC doc)
5. Shareback/listing specs require `manifest_version: 2` and typically require the app to request **`CREATE SHARE`** and **`CREATE LISTING`** privileges; the app creates a share + external listing (unpublished), then creates an app specification `TYPE = LISTING` with `TARGET_ACCOUNTS`, `LISTING`, and optional `AUTO_FULFILLMENT_REFRESH_SCHEDULE`. (Listing spec doc)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ...` | SQL command | Docs | Creates/updates a configuration request shown to consumer; supports `TYPE`, `LABEL`, `DESCRIPTION`, `APPLICATION_ROLES`, and `SENSITIVE` (STRING only). |
| `ALTER APPLICATION SET CONFIGURATION <name> VALUE = ...` | SQL command | Docs | Consumer sets configuration value; value redacted from query history if sensitive. |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Docs | Consumer can view pending configs; sensitive values are not displayed. |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE','<config>')` | Function | Docs | App can retrieve configuration values (including sensitive). |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION` | SQL command | Docs | Used for IAC connections to request server app roles and server app. |
| `ALTER APPLICATION ... APPROVE SPECIFICATION ...` | SQL command | Docs | Consumer approves connection request via SQL; also doable in Snowsight. |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = LISTING` | SQL command | Docs | Used for shareback to request target accounts + listing details. |
| `CREATE SHARE ...` | SQL command | Docs | Used by app (with privileges) to create share that exposes app-owned objects. |
| `CREATE EXTERNAL LISTING ... SHARE <share> ... PUBLISH=FALSE REVIEW=FALSE` | SQL command | Docs | Listing created in unpublished state; consumer approval workflow later governs target accounts/auto-fulfillment. |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | ACCOUNT_USAGE view | Docs | Exists, but **sensitive** values are not shown in output. |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | ACCOUNT_USAGE view | Docs | Value history; sensitive values protected/redacted. |

## MVP Features Unlocked

1. **Composable “platform” architecture for Mission Control:** split into a small “base” app + optional companion apps (e.g., governance pack, cost intelligence pack) and connect them via IAC so installs can mix-and-match.
2. **Consumer-provided configuration UX:** request endpoints/account ids/feature toggles via app configs instead of hardcoding or requiring manual SQL variables. Mark secrets (API keys/tokens) as `SENSITIVE=TRUE` to reduce leakage.
3. **Telemetry + compliance shareback pipeline (GA):** request listing spec approval for sending app usage metrics / cost insights / audit logs back to provider account(s) for aggregate analytics.

## Concrete Artifacts

### Minimal IAC + configuration handshake (SQL snippets)

```sql
-- In client app setup: request server app name
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'App to connect to for enhanced functionality'
  APPLICATION_ROLES = (app_user);

-- Consumer sets the installed server app name (consumer-side action)
ALTER APPLICATION my_client_app
  SET CONFIGURATION my_server_app
  VALUE = MY_SERVER_APP_NAME;

-- In client app: create connection specification (often in before_configuration_change callback)
ALTER APPLICATION
  SET SPECIFICATION my_server_connection
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'App to connect to for enhanced functionality'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);
```

### Shareback (listing spec) skeleton

```yaml
# manifest.yml
manifest_version: 2
privileges:
  - CREATE SHARE:
      description: "Create share for telemetry/compliance"
  - CREATE LISTING:
      description: "Create listing to share telemetry/compliance"
```

```sql
-- setup script (app-owned objects only)
CREATE SHARE IF NOT EXISTS telemetry_share;

-- grant app-created objects into the share
GRANT USAGE ON DATABASE app_db TO SHARE telemetry_share;
GRANT USAGE ON SCHEMA app_db.telemetry TO SHARE telemetry_share;
GRANT SELECT ON TABLE app_db.telemetry.events TO SHARE telemetry_share;

-- listing must be created unpublished
CREATE EXTERNAL LISTING IF NOT EXISTS telemetry_listing
  SHARE telemetry_share
  AS $$
  title: "Mission Control Telemetry"
  subtitle: "Usage & diagnostics"
  description: "Share usage metrics for support and product improvement"
  listing_terms:
    type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

-- request permission to share with provider/3rd party accounts
ALTER APPLICATION SET SPECIFICATION telemetry_shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry sharing'
  DESCRIPTION = 'Share usage metrics with provider for support and improvement'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC + application configuration are *Preview* | API/behavior may change; Snowsight UX may shift | Track release notes + test in a dedicated scratch account. |
| Sensitive configuration protections match SECRET-like behavior as documented | Leakage risk if assumptions wrong | Validate redaction in query history and SHOW/DESCRIBE outputs in a test install. |
| Shareback/listing spec operational overhead (approval flow, cross-region auto-fulfillment costs billed to consumer) | Adoption friction; cost surprises | Provide clear in-app explanation + conservative default refresh schedule; document cost implications. |

## Links & Citations

1. Inter-App Communication (Preview) release note (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Inter-app communication docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Application configuration (Preview) release note (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Application configuration docs: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
5. Shareback (GA) release note (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Request data sharing with app specifications (LISTING specs): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Prototype a tiny “server utility” app exposing a cost attribution UDF/SP via IAC; connect from Mission Control client app.
- Add an app configuration layer for external integrations (URLs/account ids) with `SENSITIVE=TRUE` where applicable.
- Sketch a shareback telemetry schema and decide minimal dataset to share (opt-in), with a conservative refresh schedule.
