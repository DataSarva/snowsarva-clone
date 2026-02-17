# Research: Native Apps - 2026-02-17

**Time:** 09:43 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake introduced **Inter-App Communication (IAC)** (Preview) enabling one Snowflake Native App to securely communicate with other Native Apps **in the same consumer account**. 
2. IAC uses a **client/server** model where a **client app** requests a connection to a **server app** and, once approved by the consumer, can call the server app’s **functions and stored procedures** (synchronously) or interact via server-managed **tables/views** (asynchronously/polling).
3. The handshake includes (a) a **CONFIGURATION DEFINITION** request to learn the server app’s installed name (since consumers can rename apps), and (b) an **APPLICATION SPECIFICATION** of type **CONNECTION** that the consumer approves in SQL or Snowsight.
4. When the consumer approves a connection spec, the framework grants the requested **server app roles** to the client app, and also grants **USAGE on the client app to the server app** so the server can see what clients are connected.
5. Snowflake’s docs explicitly warn that approving a connection can **elevate** what a client app can do indirectly (for example, if the server app has external access, the client may gain indirect access through server-exposed interfaces), so consumers should inspect server capabilities prior to approval.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App object | Native Apps docs | Used by client to request the *name* of the server app from the consumer. |
| `APPLICATION SPECIFICATION` (`TYPE = CONNECTION`) | Native App object | Native Apps docs | Client requests connection + server app roles; consumer approves/declines. |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | Command | Native Apps docs | Consumer discovers pending configuration requests. |
| `SHOW SPECIFICATIONS IN APPLICATION <app>` | Command | Native Apps docs | Consumer lists approved specs (incl. connections, EAIs, etc.). |
| `SHOW APPROVED SPECIFICATIONS` | Command | Native Apps docs | Client can retrieve current server app name at runtime from approved spec. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Bring-your-own enrichment server app” integration point:** Add an optional connector pattern where our FinOps Native App can act as an IAC **client**, letting customers connect to a separate “enrichment” server app (e.g., internal ID resolver, tagging normalizer, CMDB mapping). This avoids custom ETL and keeps the integration inside Snowflake.
2. **Connection health + audit page in-app:** Build a UI panel that surfaces *which server app is connected*, connection status, and last successful call time (client-side telemetry), plus recommended admin checks (SHOW PRIVILEGES/REFERENCES/SPECIFICATIONS) before approval.
3. **Async job pattern for cost optimization suggestions:** Define a server interface for “optimize warehouse sizing / schedule recommendations” where our app (client) submits a request row and polls for results, allowing heavier compute to run in the server app under controlled roles.

## Concrete Artifacts

### Minimal IAC handshake (client-side SQL skeleton)

```sql
-- Step 1: request the server app name from the consumer
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  APPLICATION_ROLES = (my_server_app_role);

-- Step 2: once consumer sets the configuration value, create a CONNECTION spec
ALTER APPLICATION
  SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions. The server app version must be greater than or equal to 3.2.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);
```

### Example: client retrieving server app name at runtime

```sql
SHOW APPROVED SPECIFICATIONS;

-- then (per docs) parse the definition JSON to retrieve SERVER_APPLICATION
-- and use it to qualify calls like:
-- session.call("server_app_name.schema.proc", ...)
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Feature is **Preview**; behavior/SQL surface area may change. | Integration churn; docs + examples might evolve. | Track release notes + change log; validate in a test account. |
| Indirect privilege escalation via server app interfaces (incl. external access). | Security review burden; customer admin skepticism. | Implement “pre-approve checklist” guidance; document least-privilege roles/interfaces. |
| Unclear limits/quotas around connection counts, call volume, or cross-database access patterns. | Scaling and cost surprises. | Test with synthetic load; look for any platform limits in docs once published. |

## Links & Citations

1. Release note: **Snowflake Native Apps: Inter-App Communication (Preview)** (Feb 13, 2026) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Docs: **Inter-app Communication** — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull/scan the callback reference page and note which callbacks matter for connection lifecycle + UX (e.g., creating the spec in `before_configuration_change`).
- Prototype a tiny “server app” that exposes a stored proc interface (sync) + table-queue interface (async) to validate permissions + UX in Snowsight.
- Decide how our FinOps app should present IAC: optional advanced integration vs default dependency.
