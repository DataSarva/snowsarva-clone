# Research: Native Apps - 2026-02-24

**Time:** 10:55 UTC  
**Topic:** Snowflake Native App Framework (Configuration / IAC / Shareback)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps can request **consumer-provided configuration values** via *application configurations* (Preview as of Feb 20, 2026 release note). Consumers set values through SQL or Snowsight. 
2. Configuration definitions are created by the app via `ALTER APPLICATION SET CONFIGURATION DEFINITION ...` and values are provided by consumers via `ALTER APPLICATION <app> SET CONFIGURATION <config> VALUE = '<value>'`.
3. Configurations support types `APPLICATION_NAME` (for inter-app communication) and `STRING` (arbitrary string values like URLs/account identifiers).
4. `STRING` configurations can be marked `SENSITIVE=TRUE` to protect secrets: values are redacted in query history for the ALTER command and are not shown in `SHOW CONFIGURATIONS`, `DESCRIBE CONFIGURATION`, `INFORMATION_SCHEMA` views, or `ACCOUNT_USAGE` views.
5. Apps can retrieve configuration values using system context (`SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE','<config_name>')`) and can register lifecycle callbacks to validate or react to configuration changes.
6. Native Apps can now **communicate with other apps in the same consumer account** (Inter-App Communication, Preview as of Feb 13, 2026).
7. Native Apps can now **request permission to share data back** to the provider / third parties (Shareback, GA as of Feb 10, 2026). This enables governed telemetry and compliance reporting flows.

## Snowflake Objects & Data Sources

| Object/View / Command | Type | Source | Notes |
|---|---|---|---|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION` | SQL command | Snowflake docs | App defines requested key, type, label/desc, allowed app roles, sensitivity |
| `ALTER APPLICATION ... SET CONFIGURATION ... VALUE` | SQL command | Snowflake docs | Consumer supplies value |
| `ALTER APPLICATION UNSET CONFIGURATION` | SQL command | Snowflake docs | Required to clear value before changing sensitivity |
| `SHOW CONFIGURATIONS` / `DESCRIBE CONFIGURATION` | SQL command | Snowflake docs | Consumer visibility into pending + set configs |
| `SYS_CONTEXT(..., 'GET_CONFIGURATION_VALUE', ...)` | Function (SYS_CONTEXT) | Snowflake docs | App-only retrieval path |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | INFO_SCHEMA view | Snowflake docs | Not shown for sensitive values |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | ACCOUNT_USAGE view | Snowflake docs | Not shown for sensitive values |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | ACCOUNT_USAGE view | Snowflake docs | Value history (sensitive protections apply) |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATION_VALUE_HISTORY` / `APPLICATION_CONFIGURATION_VALUE_HISTORY()` | INFO_SCHEMA TF | Snowflake docs | History access patterns |

## MVP Features Unlocked

1. **“Bring-your-own-endpoints” setup**: request consumer config for an external URL (e.g., callback endpoint, SIEM destination, ticketing base URL) and store it as a `STRING` configuration; validate with `validate_configuration_change`.
2. **Governed telemetry pipeline** (Shareback GA + Config): request an *opt-in* shareback spec and a `SENSITIVE` API key / token configuration; on config change, automatically create/update the shareback objects.
3. **Inter-App integration mode**: request `APPLICATION_NAME` configuration to bind to a “server” app (IAC), then auto-provision connection specs inside `before_configuration_change`.

## Concrete Artifacts

### Minimal config definition + retrieval pattern

```sql
-- App-side: define the request (in setup script or runtime)
ALTER APPLICATION SET CONFIGURATION DEFINITION company_url
  TYPE = STRING
  LABEL = 'Company URL'
  DESCRIPTION = 'Provide the company website URL'
  APPLICATION_ROLES = (app_user)
  SENSITIVE = FALSE;

-- Consumer-side: provide value
ALTER APPLICATION <app_name> SET CONFIGURATION company_url VALUE = 'https://example.com';

-- App-side: read value (app-only)
SELECT SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'GET_CONFIGURATION_VALUE', 'company_url');
```

### Sensitive config (tokens)

```sql
ALTER APPLICATION SET CONFIGURATION DEFINITION api_token
  TYPE = STRING
  LABEL = 'API Token'
  DESCRIPTION = 'Token used to authenticate to <service>'
  APPLICATION_ROLES = (app_admin)
  SENSITIVE = TRUE;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Feature is Preview (configuration + IAC) | Semantics/SQL surface may change; limited account availability | Verify in a test account; check doc “availability” notes + org enablement |
| Sensitive configs are protected from query history + views, but app can always retrieve | Misuse could still exfiltrate secrets within app logic | Enforce least privilege app roles + audit app code paths |
| Shareback GA details depend on listing/app spec configuration | Implementation complexity could be non-trivial | Read “requesting app specs listing” docs; build a minimal PoC |

## Links & Citations

1. Feb 20, 2026 release note: Native Apps Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Application configuration docs — https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Feb 13, 2026 release note: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Feb 10, 2026 release note: Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback

## Next Steps / Follow-ups

- Skim inter-app communication docs and extract the exact object model + SQL required for the “server app name” workflow.
- Draft an MVP “first-run setup” UX that uses configurations (including `SENSITIVE` for tokens) rather than manual SQL copy/paste.
- If we adopt Shareback for telemetry, define the minimal schema/events we want and the opt-in/retention model.
