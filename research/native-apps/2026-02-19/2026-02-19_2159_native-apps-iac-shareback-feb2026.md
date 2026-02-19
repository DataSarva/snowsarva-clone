# Research: Native Apps - 2026-02-19

**Time:** 21:59 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (IAC) is now available in Preview** and enables one Snowflake Native App to securely call functions/procedures exposed by another Snowflake Native App in the *same consumer account* (client/server model).\
   Source: Snowflake release note (Feb 13, 2026) + IAC docs.
2. IAC connections use a **handshake** built on two Native App Framework primitives:
   - `CONFIGURATION DEFINITION` of type `APPLICATION_NAME` to let the consumer provide the *actual installed name* of the target server app.
   - `APPLICATION SPECIFICATION` of type `CONNECTION` to request server app roles; the consumer approves/declines.
   Source: IAC docs.
3. **Shareback is GA**: apps can request permission from consumers to share data back to the provider (or third parties) using **LISTING-type application specifications**.\
   Source: Snowflake release note (Feb 10, 2026) + app-spec listing docs.
4. LISTING app-spec shareback requires `manifest_version: 2` and privileges including **`CREATE SHARE`** and **`CREATE LISTING`**, with the app creating the share + (unpublished) external listing, then requesting target accounts via a LISTING app-spec definition.\
   Source: app-spec listing docs.
5. Shareback query access for recipients uses the **Uniform Listing Locator (ULL)** pattern with `NATIVEAPP$<listing>` references (recipient side), as documented.\
   Source: app-spec listing docs.

## Snowflake Objects & Data Sources

| Object/View / Command | Type | Source | Notes |
|---|---|---|---|
| `ALTER APPLICATION SET CONFIGURATION DEFINITION … TYPE = APPLICATION_NAME …` | SQL command | Docs | Used by client app to ask consumer for target server app name (supports consumer custom app name at install). |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | SQL command | Docs | Consumer uses to see incoming configuration requests. |
| `ALTER APPLICATION <client_app> SET CONFIGURATION <name> VALUE = <server_app_name>` | SQL command | Docs | Consumer provides server app name to client app. |
| `ALTER APPLICATION SET SPECIFICATION … TYPE = CONNECTION … SERVER_APPLICATION = … SERVER_APPLICATION_ROLES = (…)` | SQL command | Docs | Client app requests connection to server app; approval grants requested server app roles to client. |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <spec> SEQUENCE_NUMBER = <n>` | SQL command | Docs | Server app side approval (SQL path). |
| `SHOW APPROVED SPECIFICATIONS` | SQL command | Docs | Client app can discover approved spec definition; recommended to retrieve server app name at runtime. |
| `ALTER APPLICATION SET SPECIFICATION … TYPE = LISTING … TARGET_ACCOUNTS = 'Org.Acct,…' LISTING = <listing>` | SQL command | Docs | Shareback request via listing spec. |
| `CREATE SHARE …` / `CREATE EXTERNAL LISTING …` | SQL commands | Docs | App creates the share + listing during setup/upgrade (listing must be created unpublished: `PUBLISH=FALSE`, `REVIEW=FALSE`). |
| `SHOW LISTINGS` / `DESC LISTING` (ULL via `uniform_listing_locator`) | SQL commands | Docs | Used to find ULL and validate listing configuration post-approval. |

## MVP Features Unlocked

1. **Composable “FinOps platform” via app-to-app integration (IAC):**
   - Provide a “FinOps core” app exposing procedures/functions that other apps (observability, governance, data quality, etc.) can call for cost attribution + policy checks.
   - Or: integrate with third-party vendor apps inside a consumer account (e.g., consume a “customer identity resolution” server app; emit enriched cost/usage joins).
2. **First-class, consented telemetry + compliance export (Shareback GA):**
   - Implement optional “send diagnostics / cost aggregates back to provider” pipeline using LISTING app-spec, rather than external connectivity.
   - Enable a governed support workflow: consumer approves specific target accounts; provider reads via `NATIVEAPP$<listing>`.
3. **Better “connection UX” patterns in Snowsight:**
   - Use `before_configuration_change` callback to auto-create the CONNECTION spec immediately when consumer sets the `APPLICATION_NAME` configuration (reduces manual steps).

## Concrete Artifacts

### A. IAC: minimal handshake outline (client + consumer + server)

```sql
-- Client app (setup): request server app name from consumer
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_client_app_role);

-- Consumer: provide the installed server app name (consumer may have renamed it)
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- Client app: request a connection (roles must be coordinated offline with server provider)
ALTER APPLICATION
  SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Server app: approve
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### B. Shareback: listing spec skeleton (provider design)

```yaml
# manifest.yml
manifest_version: 2
privileges:
  - CREATE SHARE:
      description: "Create a share for telemetry/compliance data"
  - CREATE LISTING:
      description: "Create a listing for shareback"
```

```sql
-- setup.sql
CREATE SHARE IF NOT EXISTS finops_shareback_share;

CREATE EXTERNAL LISTING IF NOT EXISTS finops_shareback_listing
  SHARE finops_shareback_share
  AS $$
    title: "FinOps Telemetry Shareback"
    subtitle: "Optional governed telemetry export"
    description: "Share aggregated usage/cost telemetry with provider for product improvement/support"
    listing_terms:
      type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

ALTER APPLICATION SET SPECIFICATION finops_shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Share aggregated telemetry with provider for support and analytics'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = finops_shareback_listing;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---:|---|
| IAC is **Preview** (availability/behavior may change; not in all regions/accounts). | Medium | Verify enablement + account eligibility in at least one test consumer account. |
| IAC can create **privilege escalation concerns** (client app indirectly gains server capabilities, e.g. external access). | High | Build explicit “connected-app trust model” + consumer-facing docs; test `SHOW PRIVILEGES IN APPLICATION` / `SHOW REFERENCES IN APPLICATION` inspection guidance. |
| Shareback via listing implies **consumer-billed auto-fulfillment** costs (cross-region refresh schedule). | Medium | Document cost implications; default to cost-aware schedules; provide UI toggles. |
| “Provider analytics” via listing may require careful data minimization + consent. | High | Define a schema contract; implement redaction/aggregation; add configuration to disable. |

## Links & Citations

1. Feb 13, 2026 Release Note — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. IAC docs — Inter-app communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Feb 10, 2026 Release Note — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Shareback docs — Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Draft a **“FinOps Core App as Server”** reference architecture (IAC) + security review checklist for consumers.
- Prototype a **shareback schema contract** (aggregated usage/cost + query metadata) + listing object layout.
- Decide whether Mission Control app should:
  - expose *procedures/functions* to other apps (IAC),
  - or be the *client* to other apps, or both.
