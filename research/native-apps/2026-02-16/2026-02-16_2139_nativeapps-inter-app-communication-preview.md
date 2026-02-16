# Research: Native Apps - 2026-02-16

**Time:** 21:39 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced **Inter-app Communication (IAC)** for Snowflake Native Apps as a **Preview** feature (release note dated **Feb 13, 2026**).
2. IAC enables one Native App (**client**) to securely call another Native App (**server**) in the **same consumer account**, to share/merge data or expose reusable capabilities via procedures/functions.
3. IAC uses a consumer-approved **handshake**: client requests the server app name via a **CONFIGURATION DEFINITION** (type `APPLICATION_NAME`), then requests a connection via an **APPLICATION SPECIFICATION** (type `CONNECTION`), which the consumer approves (SQL or Snowsight).
4. After approval, the framework grants the client the requested **server application roles**, enabling calls like `session.call("server_app.schema.proc", ...)`.
5. IAC supports both **synchronous** interactions (direct stored procedure/function calls) and **asynchronous** patterns (server provides procedures that enqueue work into tables/views that the client can poll).
6. Security: approving a connection can effectively **elevate** what the client app can do indirectly (e.g., if the server has external access); consumers should inspect server privileges before approving.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App SQL object | Native Apps IAC docs | Used by client app to request the *installed name* of the server app (since consumers can rename apps at install). |
| `CONFIGURATION` | Native App setting | Native Apps IAC docs | Consumer sets the server app name into the client app via `ALTER APPLICATION ... SET CONFIGURATION ... VALUE=...`. |
| `APPLICATION SPECIFICATION` (type `CONNECTION`) | Native App SQL object | Native Apps IAC docs | Client requests connection + requested server app roles. |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | Command | Native Apps IAC docs | How consumer discovers incoming config definition requests. |
| `SHOW APPROVED SPECIFICATIONS` | Command / table-like output | Native Apps IAC docs | Client should read approved spec at runtime to get server name in case it was renamed. |
| `ALTER APPLICATION ... APPROVE SPECIFICATION ... SEQUENCE_NUMBER=...` | SQL | Native Apps IAC docs | Server-side approval path via SQL. |

## MVP Features Unlocked

1. **Composable “FinOps Hub” Native App**: split capabilities into separate apps (e.g., cost intelligence, policy enforcement, anomaly detection) and let them interoperate via IAC, reducing monolith pressure and allowing independent release cadences.
2. **Pluggable provider integrations**: a “connector/app” can register standard server-side procedures (e.g., `get_usage_extract(...)`, `get_anomaly_candidates(...)`) that the main FinOps app calls through IAC.
3. **Cross-app privilege minimization**: implement a dedicated “server utility app” that owns external access integrations / secrets and exposes *narrow* procedures to client apps, instead of granting broad privileges to each app.

## Concrete Artifacts

### Minimal IAC handshake (SQL skeleton)

```sql
-- Client app: request server app name
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_server_app_role);

-- Consumer: set server name into client app
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- Client app: request connection to server app
ALTER APPLICATION
  SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Server app (consumer action): approve
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Preview feature semantics may change (SQL surface area, callbacks, permissions). | Breaking changes for early adopters; app upgrade burden. | Track release notes + test against preview accounts. |
| Indirect privilege escalation through connected server apps (esp. external access). | Security review + approval UX becomes critical for enterprise customers. | Validate with security team + document required privileges; build “least-privilege” role sets. |
| IAC only works within the same consumer account (per docs framing). | Limits cross-account scenarios; may need different architecture for org-wide services. | Confirm by testing; monitor docs for cross-account roadmap. |

## Links & Citations

1. Release note: **Feb 13, 2026: Snowflake Native Apps: Inter-App Communication (Preview)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Docs: **Inter-app Communication** — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Identify how IAC interacts with **Native App release channels** and upgrade workflows (provider side).
- Prototype a tiny two-app demo (client/server) to validate:
  - role grants visibility,
  - callback behavior,
  - synchronous vs async pattern,
  - failure modes when server app is renamed/uninstalled.
