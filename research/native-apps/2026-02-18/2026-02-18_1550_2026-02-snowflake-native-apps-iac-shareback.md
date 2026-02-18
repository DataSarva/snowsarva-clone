# Research: Native Apps - 2026-02-18

**Time:** 1550 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (IAC) is now available (Preview):** A Snowflake Native App can securely communicate with other Native Apps in the *same consumer account* by exposing procedures/functions via app roles and establishing a governed connection handshake.  
   - Source: Release note (Feb 13, 2026) + IAC docs.

2. **IAC introduces two key SQL object concepts used by the client app:**
   - A **CONFIGURATION DEFINITION** (type `APPLICATION_NAME`) to request the *installed name* of the server app (because consumers can rename apps at install time).
   - An **APPLICATION SPECIFICATION** (type `CONNECTION`) to request a connection + specific server app roles; consumer approves via SQL or Snowsight.
   - Source: IAC docs.

3. **Shareback is now GA:** Providers can request consumer permission to share data back to the provider (or designated 3rd parties) using app specifications + listings/shares. This enables telemetry/analytics sharing, compliance reporting, and support diagnostics with a governed workflow.  
   - Source: Release note (Feb 10, 2026) + “Request data sharing with app specifications” docs.

4. **Performance Explorer got new investigative affordances (Preview):** grouped recurring queries view, hour filtering, time-window drag selection, and a “previous period” comparison column—useful for FinOps-style “what changed?” workflows.  
   - Source: Release note (Feb 09, 2026).

5. **ACCESS_HISTORY records are no longer dropped when too large:** Snowflake now truncates oversized records to fit in `ACCESS_HISTORY` (with truncation indicators). This reduces blind spots for governance/forensics and any app logic relying on access-history completeness.  
   - Source: Release note (Feb 17, 2026).

## Snowflake Objects & Data Sources

| Object/View / Construct | Type | Source | Notes |
|---|---|---|---|
| `CONFIGURATION DEFINITION` (type `APPLICATION_NAME`) | Native App SQL object | Snowflake docs | Used by client app to request server app name; consumer fulfills via `ALTER APPLICATION ... SET CONFIGURATION ... VALUE=...` |
| `APPLICATION SPECIFICATION` (type `CONNECTION`) | Native App SQL object | Snowflake docs | Used for IAC handshake; consumer approves; framework grants requested server app roles |
| `APPLICATION SPECIFICATION` (type `LISTING`) | Native App SQL object | Snowflake docs | Used for shareback via listing; includes `TARGET_ACCOUNTS`, `LISTING`, optional auto-fulfillment schedule |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | Account usage view | Snowflake docs / release note | Now includes truncated records instead of dropping large ones; watch for truncation indicators |

## MVP Features Unlocked

1. **“Mission Control → Shareback Telemetry” (Native App) (PR-sized):**
   - Add an optional GA shareback channel for: app health, feature flags, anonymized usage, and “FinOps diagnostics bundle” tables.
   - Implement as a `LISTING` app specification + listing/share created during setup; fill a small telemetry schema with rolling retention.

2. **“Ecosystem mode” via IAC (Preview) (PR-sized prototype):**
   - Split the product into: (a) a lightweight “collector” app and (b) an “analysis/insights” app that can connect via IAC.
   - Use IAC for invoking enrichment procedures (e.g., ID mapping, classification, policy validation) without sharing raw tables.

3. **Governance/forensics reliability bump (PR-sized):**
   - If we use `ACCESS_HISTORY` for lineage/entitlement investigations, add a guardrail: detect truncated records and mark analyses as “partial” rather than silently missing.

## Concrete Artifacts

### IAC handshake skeleton (docs-derived)

```sql
-- Client app requests server app name (consumer can rename apps at install time)
ALTER APPLICATION
  SET CONFIGURATION DEFINITION my_server_app_name_configuration
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  APPLICATION_ROLES = (my_client_app_role);

-- Once consumer provides server name, client requests a connection
ALTER APPLICATION
  SET SPECIFICATION my_server_app_connection_spec
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for an app that will provide access to server procedures and functions.'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (my_server_app_role);

-- Consumer approves connection (sequence number required)
ALTER APPLICATION my_server_app_name
  APPROVE SPECIFICATION my_server_app_connection_spec
  SEQUENCE_NUMBER = 1;
```

### Shareback listing spec skeleton (docs-derived)

```sql
ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry/Compliance Shareback'
  DESCRIPTION = 'Share app telemetry & diagnostics with provider (optional)'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE';
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| IAC is Preview and may have limitations/behavior changes | Product design could churn | Build a thin prototype + track release notes; gate behind feature flags |
| Shareback implies careful data minimization + customer trust concerns | Adoption risk | Make shareback opt-in, transparent schemas, and strong defaults (PII-free) |
| `ACCESS_HISTORY` truncation indicators may require parsing/handling | Analytics correctness | Test on known-large statements and confirm indicators/fields |

## Links & Citations

1. Feb 13, 2026 release note: Snowflake Native Apps — Inter-App Communication (Preview)  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Inter-app communication docs  
   https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Feb 10, 2026 release note: Snowflake Native Apps — Shareback (GA)  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Request data sharing with app specifications (LISTING specs / shareback workflow)  
   https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Feb 09, 2026 release note: Performance Explorer enhancements (Preview)  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview
6. Feb 17, 2026 release note: Access history improvements  
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-17-access-history

## Next Steps / Follow-ups

- Decide whether Mission Control’s product roadmap wants an **“opt-in shareback telemetry”** story as a first-class capability.
- Prototype an IAC demo (client+server apps) to validate UX in Snowsight (configs + approvals + callbacks).
- Add a small test harness to detect/flag `ACCESS_HISTORY` truncation in any governance features.
