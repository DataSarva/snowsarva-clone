# Research: Native Apps - 2026-02-27

**Time:** 1125 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “application configurations” (Preview) let apps request consumer-provided key/value inputs**, including sensitive values that are redacted from query history and not shown in SHOW/DESCRIBE outputs. Providers define configuration definitions; consumers set values via SQL or Snowsight. (Preview feature update Feb 20, 2026)
2. **Configuration definitions support types `APPLICATION_NAME` and `STRING`**, enabling workflows like inter-app communication (store the “server app” installed name) and general settings like URLs / account identifiers / tokens. Sensitive mode is only supported for `STRING`. (Docs)
3. **Native Apps “Shareback” is GA**: apps can request permission to share data back to the provider or designated third parties via listings + shares, gated by consumer approval via app specifications. (Feature update Feb 10, 2026)
4. **Native Apps “Inter-App Communication (IAC)” is Preview**: apps in the same consumer account can securely connect, approve a CONNECTION app specification, and then call server app procedures/functions synchronously or asynchronously. (Feature update Feb 13, 2026)
5. **Budgets now support user-defined actions (SP calls) when thresholds are reached** (and at cycle start), enabling automated FinOps remediation/alerting patterns (warehouse suspension, custom notifications, audit logs). (Feature update Feb 24, 2026)
6. **On-demand accounts can view/download invoices in Snowsight** under Admin → Billing → Invoices, with role requirements (GLOBALORGADMIN in org account OR ACCOUNTADMIN+ORGADMIN in enabled account). (Feature update Feb 24, 2026)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL cmd | Docs | Consumer discovers pending config requests. |
| `DESCRIBE CONFIGURATION <cfg> IN APPLICATION <app>` | SQL cmd | Docs | Shows definition/value details (value redacted if sensitive). |
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ...` | SQL cmd | Docs | Provider requests config value + access via app roles; can set `SENSITIVE`. |
| `ALTER APPLICATION <app> SET CONFIGURATION <cfg> VALUE = '<value>'` | SQL cmd | Docs | Consumer supplies config value. |
| `SYS_CONTEXT('SNOWFLAKE$APPLICATION','GET_CONFIGURATION_VALUE','<config_name>')` | function | Docs | App reads configuration value at runtime. |
| `INFORMATION_SCHEMA.APPLICATION_CONFIGURATIONS` | view | Docs | Config definitions (DB-level info schema). |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATIONS` | view | Docs | Account-level view of app configurations. |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_CONFIGURATION_VALUE_HISTORY` | view | Docs | History of values for configurations. |
| Budget custom-action tasks in `SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY` | view | Docs | Actions run as tasks named like `BUDGET_CUSTOM_ACTION_TRIGGER_AT_%`. |

## MVP Features Unlocked

1. **First-class “consumer config wizard” in the Native App UI**
   - Detect PENDING configs via `SHOW CONFIGURATIONS IN APPLICATION` and surface a guided flow.
   - Mark sensitive settings (API keys) as `SENSITIVE=TRUE` so they don’t leak into query history.
2. **FinOps “Budget Automation Pack”** (works even without Native App install)
   - Provide an opinionated stored procedure library + setup script to attach budget custom actions (projected/actual) for: suspend warehouses, set resource monitors, notify Slack/email via notification integrations, log to a table.
3. **Native App telemetry shareback (GA) with explicit consumer consent**
   - Use LISTING app specifications to request permission to share a minimal telemetry schema back to provider; include best-practice descriptions and cost-aware AUTO_FULFILLMENT schedules.
4. **Composable apps via IAC (Preview)**
   - Build the FinOps app as a “server” exposing procedures (e.g., cost anomaly detection) that other apps can call.
   - Or, make FinOps app the “client” consuming a security/governance app’s functions.

## Concrete Artifacts

### Example: define a sensitive configuration key (provider side)

```sql
ALTER APPLICATION SET CONFIGURATION DEFINITION api_token
  TYPE = STRING
  LABEL = 'API Token'
  DESCRIPTION = 'Token used to call external cost intelligence service'
  APPLICATION_ROLES = (app_admin)
  SENSITIVE = TRUE;
```

### Example: budget custom action that calls an SP when projected usage hits 75%

```sql
CALL budget_db.sch1.my_budget!ADD_CUSTOM_ACTION(
  SYSTEM$REFERENCE('PROCEDURE', 'code_db.sch1.alert_team(string, string, string)'),
  ARRAY_CONSTRUCT('admin@example.com', 'Budget Alert', 'Projected spend hit 75%'),
  'PROJECTED',
  75
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Native Apps configuration + IAC are Preview (configuration definitely Preview; IAC Preview). | API/UX may change; avoid hard dependencies in GA product. | Track docs + release notes; test in preview accounts. |
| Sensitive configurations are only supported for `STRING` type. | `APPLICATION_NAME` cannot be “sensitive”; ensure no secrets are stored there. | Confirmed in docs. |
| Budget custom action execution semantics (retry once, max duration, throttling) require idempotent procedures. | Could cause duplicate actions (e.g., suspending warehouses twice) or missed alerts. | Implement idempotency + logging table + guardrails. |
| Invoice UI is On Demand only and role-restricted. | Not universally available; don’t build features assuming invoice access. | Confirm account type/roles; document prerequisites. |

## Links & Citations

- Release notes index (Feb 2026 entries): https://docs.snowflake.com/en/release-notes/new-features
- Native Apps: Configuration (Preview) — Feb 20, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
- Application configuration docs: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
- Native Apps: Shareback (GA) — Feb 10, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
- Request data sharing with app specifications (LISTING specs): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
- Native Apps: Inter-App Communication (Preview) — Feb 13, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
- Inter-app communication docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
- User-defined actions for budgets — Feb 24, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
- Budget custom actions docs: https://docs.snowflake.com/en/user-guide/budgets/custom-actions
- View invoices in Snowsight — Feb 24, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
- Access billing invoices docs: https://docs.snowflake.com/en/user-guide/billing-invoices

## Next Steps / Follow-ups

- Prototype: “consumer configuration wizard” UI + backend helpers for configs (detect pending, validate values, callbacks).
- Draft a minimal “telemetry shareback schema” and evaluate what’s safe to share + how to message it to consumers.
- Build a reference implementation of idempotent budget custom action procedures + logging table.
