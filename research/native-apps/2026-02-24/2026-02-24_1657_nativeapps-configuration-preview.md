# Research: Native Apps - 2026-02-24

**Time:** 16:57 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps can request **consumer-provided configuration values** via **application configurations** (Preview). The app defines configuration keys (definitions) and the consumer supplies values. 
2. Configuration definitions support at least two types: **APPLICATION_NAME** (used for inter-app communication) and **STRING** (arbitrary consumer-provided string such as URLs/account identifiers). 
3. Configurations of type STRING can be marked **SENSITIVE=TRUE**, which protects the consumer-provided value from exposure in query history/command output and from SHOW/DESCRIBE/INFORMATION_SCHEMA/ACCOUNT_USAGE visibility, while still allowing the app to retrieve the value.
4. The framework provides **configuration callbacks** that can run when a configuration value is set/changed (including synchronous validation).

## Snowflake Objects & Data Sources

| Object/View / Command / Function | Type | Source | Notes |
|---|---|---|---|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ...` | SQL command | Docs | App creates/updates configuration definitions (type, label, description, app roles, sensitive flag). |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Docs | Consumer can view pending/defined configurations (sensitive values not displayed). |
| `ALTER APPLICATION <app> SET CONFIGURATION <config> VALUE = '<value>'` | SQL command | Docs | Consumer sets the configuration value (value redacted in query history when sensitive). |
| `ALTER APPLICATION UNSET CONFIGURATION ...` | SQL command | Docs | Consumer unsets value (needed before changing SENSITIVE). |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE','<config_name>')` | Function (SYS_CONTEXT) | Docs | App retrieves configuration value. Only app can retrieve value via system context.
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | INFO_SCHEMA view | Docs | Shows config definitions (sensitive values protected). |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | ACCOUNT_USAGE view | Docs | Account-level view of app configurations. |
| `INFORMATION_SCHEMA` / `ACCOUNT_USAGE` `..._CONFIGURATION_VALUE_HISTORY` | view / table function | Docs | Tracks history of configuration values (exact shape depends on schema/object). |
| `validate_configuration_change` | callback | Docs | Synchronous validation during `ALTER APPLICATION SET CONFIGURATION VALUE`.
| `before_configuration_change` | callback | Docs | Hook to auto-create/update dependent resources (e.g., connection specs for inter-app comms) when config changes.

## MVP Features Unlocked

1. **First-class “Setup wizard” for the FinOps Native App**: request required consumer inputs (e.g., external billing export URL, org/account identifiers, optional API tokens) as configuration definitions rather than brittle manual SQL steps.
2. **Secure external integration bootstrap**: request `STRING` configs marked `SENSITIVE=TRUE` for API keys/tokens; use callbacks to validate format and to test connectivity right after the consumer sets the value.
3. **Inter-app communication wiring**: request `APPLICATION_NAME` for a “server app” name and use callbacks to automatically create/update connection specifications so the consumer doesn’t have to perform follow-on manual steps.

## Concrete Artifacts

### Example: configuration definition (URL) + sensitive token

```sql
-- request a non-sensitive URL
ALTER APPLICATION SET CONFIGURATION DEFINITION company_url
  TYPE = STRING
  LABEL = 'Company URL'
  DESCRIPTION = 'Provide the company website URL'
  APPLICATION_ROLES = (app_user)
  SENSITIVE = FALSE;

-- request a sensitive API token (STRING only)
ALTER APPLICATION SET CONFIGURATION DEFINITION billing_api_token
  TYPE = STRING
  LABEL = 'Billing API Token'
  DESCRIPTION = 'Token used to fetch billing data (stored as sensitive)'
  APPLICATION_ROLES = (app_admin)
  SENSITIVE = TRUE;
```

### Example: app retrieval

```sql
SELECT SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', 'billing_api_token');
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---:|---|
| Feature is **Preview** and could change semantics/DDL or limits. | Medium | Track release notes + docs diffs; test in a dev account with Native Apps enabled. |
| Sensitive handling is documented as similar to `SECRET` protections; actual behavior may vary across surfaces (Snowsight, query history, logs). | High | Validate with an end-to-end test: set config value, inspect query history + SHOW/DESCRIBE + account usage views, confirm redactions. |
| Callback execution model/permissions might constrain what can be auto-provisioned on config changes. | Medium | Prototype `validate_configuration_change` and `before_configuration_change` with minimal app + logs. |

## Links & Citations

1. Release note: Feb 20, 2026 — Snowflake Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Docs: Application configuration: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration

## Next Steps / Follow-ups

- Pull and summarize the callback doc section specifically for configuration callbacks (and verify what can be done in each callback).
- Prototype a minimal Native App that requests a sensitive token + validates it + triggers a follow-on setup action.
- Identify which FinOps app settings should become configs vs parameters stored in app tables (and document the boundary).