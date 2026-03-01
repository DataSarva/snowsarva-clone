# Research: Native Apps - 2026-02-28

**Time:** 2342 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Inter-app communication (IAC) is now available (Preview)**, allowing one Snowflake Native App (client) to securely call another app’s (server) procedures/functions within the same consumer account, with access controlled via app roles. (Preview announced Feb 13, 2026)  
   Source: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac and https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
2. **Application configurations are now available (Preview)**, letting an app request consumer-provided key/value inputs (types include `APPLICATION_NAME` and `STRING`). (Preview announced Feb 20, 2026)  
   Source: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration and https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. **Configuration values can be marked sensitive** (`SENSITIVE = TRUE` for `STRING` configs). Sensitive values are redacted from query history output and do not appear in `SHOW CONFIGURATIONS`, `DESCRIBE CONFIGURATION`, Information Schema, or Account Usage views; the app can still retrieve them via `SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', ...)`.  
   Source: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
4. IAC relies on a **handshake**: the client app requests the server app name via a **CONFIGURATION DEFINITION** (`TYPE = APPLICATION_NAME`), then creates an **APPLICATION SPECIFICATION** (`TYPE = CONNECTION`) requesting server app roles; the consumer approves the connection (SQL or Snowsight), after which the framework grants the requested roles to the client app and triggers callbacks.  
   Source: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ...` | DDL | SQL reference | Creates/updates configuration definition (request) shown to consumer. |
| `ALTER APPLICATION SET CONFIGURATION <name> VALUE = ...` | DDL | SQL reference | Consumer sets config value (string/app name). |
| `ALTER APPLICATION UNSET CONFIGURATION ...` | DDL | SQL reference | Required to unset before changing SENSITIVE property. |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | Command | SQL reference | Consumer/admin inspects pending configs; sensitive values are not shown. |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', '<config>')` | Function | SQL reference | App retrieves configuration value (works even when sensitive). |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION ...` | DDL | Native Apps framework | Client app requests connection to server app + requested server app roles. |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <spec> SEQUENCE_NUMBER = <n>` | DDL | Native Apps framework | Consumer approves connection request (grants roles). |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | View | `ACCOUNT_USAGE` | Row per configuration (value redacted if sensitive). |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | View | `ACCOUNT_USAGE` | History of configuration values (value redacted if sensitive). |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | View | `INFO_SCHEMA` | Current configurations in DB context (value redacted if sensitive). |
| `APPLICATION_CONFIGURATION_VALUE_HISTORY(...)` | Table function | `INFO_SCHEMA` | Returns config value history (value redacted if sensitive). |


**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **FinOps “server app” pattern (IAC):** Split the product into (a) a core *FinOps metrics & recommendations* server app exposing stable procedures/UDFs and (b) a thin UI/client app(s) that call into it. This enables composability and future partner integrations inside the consumer account.
2. **Bring-your-own-credentials config (SENSITIVE=TRUE):** Add an optional configuration key for third-party integrations (PagerDuty/Slack/Teams webhook, ticketing API token, etc.) without leaking secrets to query history/command output.
3. **Zero-click connection workflow:** Use `before_configuration_change` callback to auto-create/update the CONNECTION specification immediately after the consumer sets the server app name, reducing setup friction.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Client app setup-script sketch (request server app + later connect)

```sql
-- 1) Request the server app name from the consumer (IAC uses APPLICATION_NAME)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION finops_server_app
  TYPE = APPLICATION_NAME
  LABEL = 'FinOps Server App'
  DESCRIPTION = 'Name of the FinOps server app to connect to for cost intelligence.'
  APPLICATION_ROLES = (app_user);

-- 2) Example: request a sensitive external integration token
ALTER APPLICATION
  SET CONFIGURATION DEFINITION alerting_token
  TYPE = STRING
  LABEL = 'Alerting token'
  DESCRIPTION = 'API token for outbound alerting integration.'
  APPLICATION_ROLES = (app_admin)
  SENSITIVE = TRUE;

-- 3) In a callback (before_configuration_change), once finops_server_app is set,
-- create/update a CONNECTION specification to request server roles.
-- (Pseudo; see docs for exact syntax/sequence number patterns)
ALTER APPLICATION
  SET SPECIFICATION finops_server_connection
  TYPE = CONNECTION
  LABEL = 'FinOps Server'
  DESCRIPTION = 'Connection to the FinOps server app for procedures/UDFs.'
  SERVER_APPLICATION = <server_app_name_from_configuration>
  SERVER_APPLICATION_ROLES = (finops_server_role);
```

### App-side retrieval of config values

```sql
-- Within the app, retrieve configuration values (works for sensitive STRING values too)
SELECT SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', 'alerting_token');
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC + app configuration are **Preview** features (not GA). | Possible behavior/UX/API changes; may not be available in all accounts/regions. | Confirm availability in target accounts; track release notes for GA. |
| Offline coordination is needed to know which **server app roles** to request. | Integration onboarding may require out-of-band documentation/agreements. | Document required roles + provide a guided setup screen. |
| Sensitive configuration values are hidden from consumer tooling outputs by design. | Troubleshooting can be harder for consumer admins. | Provide “test connection” procedures that return non-sensitive diagnostics. |

## Links & Citations

1. Snowflake release note: *Feb 20, 2026 — Snowflake Native Apps: Configuration (Preview)*  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Docs: *Application configuration* (incl. sensitive configs, callbacks, objects/views)  
   https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Snowflake release note: *Feb 13, 2026 — Snowflake Native Apps: Inter-App Communication (Preview)*  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Docs: *Inter-app communication* (workflow, CONNECTION specifications, approvals, role grants)  
   https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Decide whether Mission Control should implement an internal **"FinOps Server App"** API surface (procedures/UDFs) specifically intended for IAC clients.
- Prototype: minimal client+server apps that (1) request `APPLICATION_NAME` config, (2) auto-create CONNECTION spec in callback, (3) call a server procedure.
- Add an “integration settings” page that maps to app configurations (including sensitive ones) + a non-sensitive health check.

