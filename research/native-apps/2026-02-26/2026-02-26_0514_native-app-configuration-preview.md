# Research: Native Apps - 2026-02-26

**Time:** 05:14 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake introduced **Native Apps: Configuration (Preview)**, allowing apps to request consumer-provided configuration values via **application configurations**; configurations can be marked **sensitive** to prevent exposure in query history and command output.\[1\]
2. Application configurations support at least two types: `APPLICATION_NAME` (commonly used for inter-app communication) and `STRING` (arbitrary values like URLs/account identifiers).\[2\]
3. When a configuration is marked `SENSITIVE = TRUE` (supported only for `STRING`), the value is redacted/masked: it is not shown in `SHOW CONFIGURATIONS`, `DESCRIBE CONFIGURATION`, INFORMATION_SCHEMA views, or ACCOUNT_USAGE views, and the `ALTER APPLICATION ... SET CONFIGURATION VALUE` query text is redacted; the **app can still retrieve the value** via SYS_CONTEXT.\[2\]
4. Snowflake introduced **Native Apps: Inter-App Communication (Preview)**, enabling apps in the same consumer account to securely connect and call each other using a handshake based on **configuration definitions** and **application specifications** (type `CONNECTION`).\[3\]
5. **Native Apps: Shareback** is **General Availability** as of Feb 10, 2026, allowing apps to request permission to share data back to the provider or designated third parties using app specifications.\[4\]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION` | SQL command | Docs | Defines a configuration request (key + metadata + roles + sensitivity). \[2\] |
| `ALTER APPLICATION SET CONFIGURATION VALUE` | SQL command | Docs | Consumer supplies a value (query text redaction applies to sensitive values). \[2\] |
| `ALTER APPLICATION UNSET CONFIGURATION` | SQL command | Docs | Consumer unsets a value; required to change `SENSITIVE` flag. \[2\] |
| `SHOW CONFIGURATIONS`, `DESCRIBE CONFIGURATION` | SQL commands | Docs | Consumer/admin inspection; sensitive values are not displayed. \[2\] |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE', '<config>')` | Function | Docs | App retrieves the value (including sensitive values). \[2\] |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | Info schema view | Docs | Exists; sensitive values are not displayed. \[2\] |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATION_VALUE_HISTORY` | Info schema function | Docs | Value history surface (details TBD; sensitive handling per docs). \[2\] |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | Account usage view | Docs | Account-wide view; sensitive values are not displayed. \[2\] |
| `ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | Account usage view | Docs | Value history surface (details TBD; sensitive handling per docs). \[2\] |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION` | SQL command | Docs | Used for inter-app communication connection requests. \[5\] |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App “Admin Setup” screen → backed by configuration definitions**
   - Define `STRING` configs for: billing account id, preferred notification channel/webhook URL, optional 3rd-party API keys.
   - Mark secrets as `SENSITIVE = TRUE` so they don’t leak via `SHOW`/history, while still accessible inside the app.

2. **Pluggable “server app” integrations via IAC**
   - Use a config of type `APPLICATION_NAME` for a “cost intelligence provider app” name.
   - In `before_configuration_change`, automatically create/update the `CONNECTION` specification.

3. **Telemetry / chargeback export via Shareback GA**
   - Implement a governed “export” flow that requests consumer permission to share aggregate cost/usage datasets back to provider (or a designated 3rd party) using app specifications.

## Concrete Artifacts

### Example: Request a sensitive string configuration

```sql
ALTER APPLICATION SET CONFIGURATION DEFINITION provider_api_key
  TYPE = STRING
  LABEL = 'Provider API Key'
  DESCRIPTION = 'API key used for sending anonymized cost telemetry (optional)'
  APPLICATION_ROLES = ( app_admin )
  SENSITIVE = TRUE;
```

### Example: Read the configuration value inside the app

```sql
SELECT SYS_CONTEXT(
  'SNOWFLAKE$APPLICATION',
  'GET_CONFIGURATION_VALUE',
  'provider_api_key'
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Configuration” is listed as Preview; exact rollout/regions/behavior may vary by account | Feature may be unavailable for some customers or behave differently | Confirm feature flag availability in target accounts; test in dev org | 
| Sensitive configuration protections are described as “similar to SECRET”; exact audit/visibility semantics may differ | Could affect security review or admin expectations | Validate with `SHOW CONFIGURATIONS`, query history, ACCOUNT_USAGE/INFO_SCHEMA behavior in a test account | 
| Shareback GA + IAC Preview can combine into multi-app ecosystems; security posture is non-trivial | Consumer security teams may block if perceived as privilege escalation | Document required privileges; add least-privilege defaults; provide an approval checklist | 

## Links & Citations

1. Snowflake Release Note (Feb 20, 2026): Native Apps: Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Snowflake Docs: Application configuration — https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Snowflake Release Note (Feb 13, 2026): Native Apps: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Snowflake Release Note (Feb 10, 2026): Native Apps: Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
5. Snowflake Docs: Inter-app Communication — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Add a “Configuration” module to our Native App architecture notes: mapping config keys → UI → validation callbacks → usage in stored procedures.
- Prototype end-to-end: `SENSITIVE` config set by consumer → redaction verified in query history + `SHOW` output → retrieved in app runtime.
- Decide which settings should be configuration vs SECRET vs external access integration, and document tradeoffs.
