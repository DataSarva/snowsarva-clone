# Research: Native Apps - 2026-02-21

**Time:** 04:19 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced **Inter-app Communication (IAC)** for Snowflake Native Apps as a **Preview** capability (release note dated **Feb 13, 2026**). 
2. IAC enables a “client” app to call **functions/procedures** exposed by a “server” app installed in the **same consumer account**, using a handshake/approval workflow.
3. App developers enable IAC by (a) defining **interfaces**, (b) using **application roles** to control access to those interfaces, and (c) choosing **synchronous** (direct function/procedure calls) vs **asynchronous** (results written to tables/views and polled) interaction.
4. Because consumers can rename apps during install, a client app must first request the **server app name** via a **CONFIGURATION DEFINITION** object of type `APPLICATION_NAME`, then request a connection via an **APPLICATION SPECIFICATION** of type `CONNECTION`.
5. A consumer approves a connection request by running `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <connection_spec> SEQUENCE_NUMBER = <n>` (or via Snowsight UI).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App SQL object | Native Apps docs | Used by client app to request server app name (`TYPE = APPLICATION_NAME`). |
| `CONFIGURATION` | Native App SQL object | Native Apps docs | Consumer sets the configuration value to the chosen server app name. |
| `APPLICATION SPECIFICATION` | Native App SQL object | Native Apps docs | Client app requests connection (`TYPE = CONNECTION`) incl. requested server app roles. |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Native Apps docs | Consumer discovers pending configuration requests. |
| `ALTER APPLICATION ... SET SPECIFICATION ...` | SQL command | Native Apps docs | Creates the connection request from client side. |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION ...` | SQL command | Native Apps docs | Consumer approves granting server app roles to client app. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Composable FinOps app integrations:** Let our FinOps Native App act as a “server” that exposes *stable* stored procedures like `GET_COST_SUMMARY(...)`, so other marketplace apps can embed FinOps insights without exporting data.
2. **Pluggable “enrichers” via IAC:** Support optional integration with 3rd-party enrichment apps (e.g., tag standardization, org hierarchy, workload classification). Our app becomes the “client” that calls those apps when installed.
3. **Connection UX + safety checks:** Add an in-app “Connections” panel that explains what roles are requested/granted, plus a validation stored proc that confirms server app version compatibility (as mentioned in the `DESCRIPTION` patterns in docs).

## Concrete Artifacts

### Skeleton SQL (client-side) to request a server app name + connection

```sql
-- Step 1: client app requests which server app to connect to
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_client_app_role);

-- Step 2: once consumer sets CONFIGURATION VALUE, client app creates a CONNECTION spec
ALTER APPLICATION
  SET SPECIFICATION my_server_app_connection_spec
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview feature semantics may change (SQL syntax, roles model, UI behavior). | Potential rework if we build on it early. | Confirm in Snowflake docs + track release notes until GA. |
| Requires offline coordination to know which server app roles to request. | Marketplace integrations need partner agreements / docs. | Define a partner integration contract + versioning scheme. |
| Security model complexity (role grants between apps) could confuse consumers. | Increased install friction / support tickets. | Build explicit UI + preflight checks; document permissions clearly. |

## Links & Citations

1. Release note (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Native Apps docs: Inter-app Communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull the **Security considerations** section (and any limits/constraints) from the IAC docs once we need to implement; summarize into an internal integration checklist.
- Draft an “IAC integration contract” for partner apps: required app roles, proc/function signatures, versioning + backwards-compat expectations.
