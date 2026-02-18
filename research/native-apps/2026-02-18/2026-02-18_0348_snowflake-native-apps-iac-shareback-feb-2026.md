# Research: Native Apps - 2026-02-18

**Time:** 0348 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-App Communication (IAC) is now available in Preview** and allows Snowflake Native Apps to securely communicate with other apps **in the same consumer account**, enabling apps to expose functions/procedures for other apps to call.  
   Source: Snowflake release note (Feb 13, 2026).  
2. IAC uses a **client/server app model** and a **handshake** based on a **CONFIGURATION DEFINITION** (type `APPLICATION_NAME`) plus an **APPLICATION SPECIFICATION** (type `CONNECTION`) that the consumer approves; approval grants the requested server app roles to the client app.  
   Source: IAC developer documentation.
3. **Native Apps “Shareback” is GA**: an app can request consumer permission to share data back to the provider (or designated third parties) using **app specifications for LISTING-based sharing**; positioned for compliance reporting and telemetry/analytics sharing.  
   Source: Snowflake release note (Feb 10, 2026) + “Request data sharing with app specifications” doc.
4. **ACCESS_HISTORY no longer drops oversized records**; instead, Snowflake truncates enough data to fit and includes indicators where values were truncated. This should reduce “missing” lineage/audit events when records are large.  
   Source: Snowflake feature update (Feb 17, 2026) + ACCESS_HISTORY view docs.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App SQL object | Native App Framework (consumer-approved flow) | Used by client app to request the server app name; IAC uses type `APPLICATION_NAME`. |
| `APPLICATION SPECIFICATION` | Native App SQL object | Native App Framework (consumer-approved flow) | IAC uses type `CONNECTION`; Shareback uses type `LISTING`. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Feb 17 update: oversized records are truncated instead of being excluded; truncation indicators present (e.g., `-1` number fields, `TRUNCATED` strings). |

## MVP Features Unlocked

1. **App-to-app “capability plugin” pattern (Preview):** ship a thin “FinOps Core” Native App that exposes procedures/functions (server app) for other apps (clients) to call for standard cost/telemetry primitives (e.g., compute attribution, tag hygiene scoring). Use IAC’s role-based interface to keep privilege boundaries explicit.
2. **Shareback-based telemetry export (GA):** implement provider telemetry pipelines where the consumer explicitly approves a LISTING spec to share back aggregated usage/cost metrics (and/or diagnostics) to a provider account. This can be a first-class, governed alternative to “bring your own external destination”.
3. **More reliable governance/audit signals:** update any internal “data accessed / modified” lineage features to tolerate truncation instead of treating missing ACCESS_HISTORY records as “no access”. Add UI/logic to mark events as truncated.

## Concrete Artifacts

### IAC: minimal handshake skeleton (SQL)

```sql
-- (Client app) Request the server app name from the consumer
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_server_app_role);

-- (Consumer) View incoming configuration requests
SHOW CONFIGURATIONS IN APPLICATION my_server_app_name;

-- (Consumer) Provide the resolved server app name back to the client
ALTER APPLICATION my_client_app_name
  SET CONFIGURATION my_server_app_name_configuration
  VALUE = MY_SERVER_APP_NAME;

-- (Client app) Request a connection via application specification
ALTER APPLICATION SET SPECIFICATION my_server_app_name_connection_specification
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- (Consumer) Approve connection request (server side)
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_name_connection_specification
  SEQUENCE_NUMBER = 1;
```

### Shareback (LISTING spec): skeleton (SQL)

```sql
-- In app install/upgrade setup script (requires manifest_version: 2)
CREATE SHARE IF NOT EXISTS telemetry_share;

CREATE EXTERNAL LISTING IF NOT EXISTS telemetry_listing
  SHARE telemetry_share
  AS $$
  title: "App Telemetry"
  subtitle: "Approved telemetry shareback"
  description: "Aggregated usage/cost metrics shared back to the provider"
  listing_terms:
    type: "OFFLINE"
  $$
  PUBLISH = FALSE
  REVIEW = FALSE;

ALTER APPLICATION SET SPECIFICATION telemetry_shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Share aggregated metrics with provider for product improvement and support'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing;
```

### ACCESS_HISTORY: truncation-aware querying hint

```sql
-- When parsing ACCESS_HISTORY JSON, treat -1 and TRUNCATED as truncation indicators
-- (Exact parsing depends on your derived schema)
SELECT query_id, query_start_time, user_name,
       direct_objects_accessed, base_objects_accessed
FROM snowflake.account_usage.access_history
WHERE query_start_time >= dateadd('day', -1, current_timestamp())
ORDER BY query_start_time DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is **Preview** and may change. | Product surface area may break; avoid hard dependencies for GA roadmap. | Track release notes + doc diffs; prototype behind feature flags. |
| IAC can create **privilege escalation paths** (client inherits server capabilities indirectly). | Security review required; consumers must understand server app privileges. | Follow IAC “Security considerations”; add explicit capability disclosures in UI + docs. |
| Shareback requires careful **data minimization** + clear consent. | Over-collection or unclear purpose can block adoption. | Define strict schemas, aggregate by default; explain “why” in spec description. |
| Access History truncation indicators are easy to miss. | Incorrect lineage/audit conclusions if truncation treated as “complete”. | Add truncation flagging + UI warnings. |

## Links & Citations

1. Feb 13, 2026 release note — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. IAC developer docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Feb 10, 2026 release note — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Shareback/listing specs doc: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Feb 17, 2026 feature update — Access history improvements: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-17-access-history
6. ACCESS_HISTORY view docs (truncation indicators): https://docs.snowflake.com/en/sql-reference/account-usage/access_history

## Next Steps / Follow-ups

- Prototype: build a minimal two-app IAC demo (client calls server procedure) to validate packaging + approval UX in Snowsight.
- Design: define a “telemetry shareback” schema and decide what must be aggregated/anonymized by default.
- Implementation: update any Access History ingestion/parsers to handle truncation indicators explicitly.
