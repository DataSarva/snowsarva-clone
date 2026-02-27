# Research: Native Apps - 2026-02-27

**Time:** 1735 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps can now request configuration values from consumers via **application configurations** (Preview). Apps define configuration keys for consumer-provided values (e.g., external URL, account identifier, or the name of a “server app” used for inter-app communication).
2. Configuration values can be marked **sensitive**, intended to protect secrets (e.g., API keys / access tokens) from exposure in **query history** and **command output**.
3. Snowflake Native Apps now support **Inter-App Communication** (Preview), enabling secure communication between apps in the same consumer account to share/merge data across apps.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Application configuration (keys + values) | Native App framework capability | Release notes | Exact DDL/commands not in release note; see docs link. |
| Inter-app communication “server app” | Native App pattern | Release notes | Config feature explicitly calls out collecting server app name as a config value. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Consumer setup wizard with first-class secrets handling**: In the installer/setup flow, collect required values (e.g., webhook URLs, API tokens, Slack endpoints) using app configurations marked sensitive, instead of brittle “paste into SQL” instructions.
2. **Composable “Mission Control + companion apps”**: Split capabilities across multiple Native Apps (e.g., a core FinOps app + a governance/observability add-on) and connect them via Inter-App Communication (IAC) to share normalized telemetry tables.
3. **Bring-your-own integrations**: Let the consumer specify integration endpoints/IDs (e.g., ServiceNow instance, PagerDuty routing key id) as configuration keys, enabling multi-tenant safe operation without shipping a custom build per customer.

## Concrete Artifacts

### Configuration keys to standardize (proposal)

```yaml
# Proposed configuration surface for Mission Control
config:
  required:
    - name: ALERT_WEBHOOK_URL
      type: string
      sensitive: true
    - name: DEFAULT_WAREHOUSE_PATTERN
      type: string
      sensitive: false
    - name: BUDGET_POLICY_MODE
      type: enum
      values: ["notify", "auto_suspend", "auto_resize"]
      sensitive: false
  optional:
    - name: COMPANION_APP_NAME
      type: string
      sensitive: false
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview features may have limitations, regional rollout differences, or contract changes (APIs/DDL may change). | Could require conditional logic / feature detection in app code. | Read the docs pages and capture any “limitations / availability” sections; test in a preview-enabled account. |
| “Sensitive” configs reduce exposure in query history/output, but do not automatically imply encryption-at-rest guarantees or absolute secrecy across all surfaces. | Over-promising security properties would be risky. | Confirm exact threat model and documented guarantees in Snowflake docs. |

## Links & Citations

1. Release note (Feb 20, 2026) — “Snowflake Native Apps: Configuration (Preview)”: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Docs — “Application configuration”: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Release note (Feb 13, 2026) — “Snowflake Native Apps: Inter-App Communication (Preview)”: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Docs — “Inter-app Communication”: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Extract exact syntax/objects for app configuration (DDL, how to mark sensitive, how consumers provide values) and turn into Mission Control installer UX.
- Decide on an internal “config registry” abstraction so we can support both (a) app configurations and (b) fallback mechanisms if not available.
