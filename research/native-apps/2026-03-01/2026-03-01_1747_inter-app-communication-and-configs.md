# Research: Native Apps - 2026-03-01

**Time:** 1747 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake Native Apps now support **Inter-app Communication (IAC)** in *Preview*, allowing one app (client) to connect to another app (server) in the same consumer account and call the server app’s functions/procedures via granted app roles. [1] [2]
2. IAC relies on a consumer-mediated “handshake” where the client app requests the server app’s *installed name* via **application configuration** (type `APPLICATION_NAME`), then requests a connection via an **application specification** (type `CONNECTION`) that the consumer approves. [1] [2]
3. Snowflake Native Apps now support **Application Configurations** in *Preview*, letting apps request consumer-provided key/value settings (types: `APPLICATION_NAME` and `STRING`). Configurations can be marked **SENSITIVE** (STRING-only) to avoid exposure in query history and command output. [3] [4]
4. Snowflake Native Apps **Shareback** is **GA**, enabling an app to request consumer permission (via listing/app-spec mechanisms) to share data back to the provider and/or designated third-party accounts; this supports telemetry, compliance reporting, troubleshooting, and preprocessing workflows. [5] [6]

## Snowflake Objects & Data Sources

| Object/View / Function | Type | Source | Notes |
|---|---|---|---|
| `ALTER APPLICATION ... SET CONFIGURATION DEFINITION ...` | SQL command | Native Apps framework | Creates/updates config requests shown to consumer. [4] |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Native Apps framework | Consumer can view pending config requests. [2] [4] |
| `ALTER APPLICATION <app> SET CONFIGURATION <config> VALUE = ...` | SQL command | Native Apps framework | Consumer sets configuration value; value can be redacted if sensitive. [2] [4] |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE','<config>')` | Function (SYS_CONTEXT) | Native Apps framework | App reads configuration value at runtime (including sensitive). [4] |
| `ALTER APPLICATION SET SPECIFICATION <name> TYPE = CONNECTION ...` | SQL command | Native Apps framework | Client app requests connection to server app; consumer approves. [2] |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <name> SEQUENCE_NUMBER = <n>` | SQL command | Native Apps framework | Server app approves connection request. [2] |
| `ALTER APPLICATION SET SPECIFICATION <name> TYPE = LISTING ...` | SQL command | Native Apps framework | Requests permission to share data via listing target accounts / auto-fulfillment schedule. [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | Account Usage view | `ACCOUNT_USAGE` | Metadata visibility of app configs (note: sensitive values are not shown). [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | Account Usage view | `ACCOUNT_USAGE` | History for configurations (sensitive values protected). [4] |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | Info Schema view | `INFO_SCHEMA` | Per-db view of app configs where applicable; sensitive values not shown. [4] |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Connect to other apps” integration surface** for the FinOps Native App:
   - Implement an optional IAC client that can connect to a “server app” (e.g., an org’s internal governance app, ticketing app, or an enrichment app) to fetch org metadata (cost center mappings, ownership, policy) using server-provided stored procedures.
   - Use `CONFIGURATION DEFINITION` (type `APPLICATION_NAME`) + `CONNECTION` spec handshake, so the consumer can pick which app to connect to in Snowsight.
2. **Secure onboarding for external integrations** (without secrets leaking to query history):
   - Request `STRING` configurations marked `SENSITIVE=TRUE` for things like webhook URLs, API tokens, or customer identifiers.
   - Use configuration callbacks (`validate_configuration_change`, `before_configuration_change`) to validate formats and create/update dependent objects.
3. **Opt-in telemetry / diagnostic shareback channel (GA capability)**:
   - Create an app-owned database/schema that stores aggregated usage telemetry (e.g., feature usage counts, version, anonymized stats), then request shareback permission via LISTING app specification to the provider account.
   - Keep it off by default; clearly document what data is shared and why.

## Concrete Artifacts

### A) IAC handshake skeleton (client app)

```sql
-- 1) Request server app name from consumer (shown in Snowsight "Configurations")
ALTER APPLICATION
  SET CONFIGURATION DEFINITION finops_server_app
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Select an installed server app to integrate with (IAC).'
  APPLICATION_ROLES = (app_user);

-- 2) In before_configuration_change callback, create/update the connection specification
-- (Pseudo: done inside a callback proc)
ALTER APPLICATION
  SET SPECIFICATION finops_server_app_conn
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Select an installed server app to integrate with (IAC).'
  SERVER_APPLICATION = <SERVER_APP_NAME_FROM_CONFIG>
  SERVER_APPLICATION_ROLES = (<server_app_role_from_offline_coordination>);
```

### B) Sensitive configuration request example (consumer-provided secret)

```sql
ALTER APPLICATION SET CONFIGURATION DEFINITION provider_api_token
  TYPE = STRING
  LABEL = 'Provider API Token'
  DESCRIPTION = 'Token used for optional provider integration.'
  APPLICATION_ROLES = (app_admin)
  SENSITIVE = TRUE;

-- App reads it (inside app context):
SELECT SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', 'PROVIDER_API_TOKEN');
```

### C) Shareback via LISTING specification skeleton

```sql
-- Provider-side app requests ability to create share/listing via manifest_version: 2 + privileges.
-- Then app creates share + external listing in setup.

ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Optional: share aggregated telemetry/diagnostics back to provider.'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| IAC is *Preview* | Breaking changes / limited regional availability possible | Track future release notes; validate in target Snowflake accounts. [1] |
| IAC requires offline coordination of server app role names | Provider-to-provider agreement needed for stable integration | Document expected roles + version constraints in provider docs; add validation callback. [2] |
| Sensitive configs are retrievable by the app by design | Potential data exfil concern; must be explicit in UX | Ensure app code limits storage/logging; document purpose and retention. [4] |
| Shareback requires careful scoping of shared objects | Over-sharing could create compliance risk | Keep share dataset minimal, aggregated, and documented; add explicit opt-in. [5] [6] |

## Links & Citations

1. Release note: Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Docs: Inter-app communication (IAC): https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Docs: Application configuration: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
5. Release note: Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Docs: Request data sharing with app specifications (LISTING): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Implement a thin proof-of-concept IAC client/server pair inside our repo to validate the callback wiring + Snowsight approval UX.
- Decide what “shareback” telemetry we actually want (if any) for the FinOps app; draft a data contract + minimal schema.
- Add an onboarding step in the app UI for Configurations (including sensitive token entry) with explicit opt-in language.
