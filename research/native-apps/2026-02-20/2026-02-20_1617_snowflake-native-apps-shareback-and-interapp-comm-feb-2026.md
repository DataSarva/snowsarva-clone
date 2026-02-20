# Research: Native Apps - 2026-02-20

**Time:** 1617 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Snowflake Native Apps “Shareback” is GA (Feb 10, 2026).** Apps can request consumer permission to share data back to the provider or designated third parties via listings/app specifications.  
   Source: Snowflake release note (Feb 10, 2026) for Native Apps Shareback (GA). (Link in citations)

2. **Snowflake Native Apps “Inter-App Communication (IAC)” is in Preview (Feb 13, 2026).** Apps in the same consumer account can securely communicate by exposing procedures/functions via interfaces controlled by app roles, with a consumer-approved connection workflow.  
   Source: Snowflake release note (Feb 13, 2026) + IAC doc page. (Links in citations)

3. **Two new ACCOUNT_USAGE views provide per-request credit/token attribution for AI agent usage (Preview, Feb 18, 2026).**
   - `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (per Snowflake Intelligence interaction; includes aggregated + granular tokens/credits and metadata like request_id, user, agent_id).
   - `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` (per Cortex Agent interaction; includes tokens/credits and metadata).
   Sources: Snowflake release notes (Feb 18, 2026) + view reference pages. (Links in citations)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = LISTING ...` | DDL / App spec | Native Apps docs | Core mechanism for Shareback permissioning via listings. |
| `CREATE SHARE` / `CREATE LISTING` | DDL | Native Apps docs | Required for Shareback workflow (app creates share + external listing). |
| `SHOW CONFIGURATIONS IN APPLICATION <app>` | Command | IAC docs | Consumer can see incoming configuration definition requests. |
| `ALTER APPLICATION SET CONFIGURATION DEFINITION ... TYPE = APPLICATION_NAME` | DDL | IAC docs | Client app requests the server app’s installed name (consumer may rename at install). |
| `ALTER APPLICATION SET SPECIFICATION ... TYPE = CONNECTION ...` | DDL / App spec | IAC docs | Client app requests a connection to server app (consumer approves). |
| `ALTER APPLICATION <server_app> APPROVE SPECIFICATION <name> SEQUENCE_NUMBER = <n>` | DDL / Approval | IAC docs | Server-side approval step for connection workflow. |
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview. Provides tokens/credits + granular breakdown arrays for spend attribution. |
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview. Similar attribution for Cortex Agents. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“Native App Telemetry Shareback” pattern (provider-side FinOps + product analytics).**
   - In our FinOps Native App: request permission to share anonymized usage + cost signals back to provider for fleetwide benchmarking.
   - Use LISTING app spec + callback on approval/decline to start/stop populating shared tables.

2. **Composable “FinOps platform” via IAC (app-to-app integrations).**
   - Build an “adapter” interface (procedures/functions) so other Native Apps can call into our app for cost classification, anomaly scoring, or policy checks.
   - Enables a network effect: our app becomes a shared service inside the consumer account.

3. **First-class AI spend observability.**
   - Add dashboards/alerts over new AI usage views to attribute Snowflake Intelligence / Cortex Agent credits by user, tag, agent, request.
   - Use `*_GRANULAR` arrays to break down by service_type/model and surface “cache_read_input vs output” cost dynamics.

## Concrete Artifacts

### A) Shareback spec SQL skeleton (LISTING app specification)

```sql
-- In setup script (after CREATE SHARE / CREATE LISTING)
ALTER APPLICATION SET SPECIFICATION shareback_spec
  TYPE = LISTING
  LABEL = 'Telemetry Shareback'
  DESCRIPTION = 'Share anonymized telemetry/cost metrics with provider for support + benchmarking'
  TARGET_ACCOUNTS = 'ProviderOrg.ProviderAccount'
  LISTING = telemetry_listing
  -- Required only for cross-region shareback
  -- AUTO_FULFILLMENT_REFRESH_SCHEDULE = '720 MINUTE'
;
```

### B) IAC handshake SQL skeleton (client-side)

```sql
-- Client app requests the installed name of the server app
ALTER APPLICATION
  SET CONFIGURATION DEFINITION server_app_name
  TYPE = APPLICATION_NAME
  LABEL = 'Server App'
  DESCRIPTION = 'Server app providing FinOps interfaces'
  APPLICATION_ROLES = (client_app_role);

-- After consumer sets the configuration VALUE, client creates the connection spec
ALTER APPLICATION
  SET SPECIFICATION finops_server_connection
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Server app providing FinOps interfaces'
  SERVER_APPLICATION = MY_SERVER_APP_NAME
  SERVER_APPLICATION_ROLES = (server_app_role);
```

### C) AI spend visibility (new ACCOUNT_USAGE views)

```sql
-- Snowflake Intelligence usage
SELECT
  start_time,
  end_time,
  user_name,
  snowflake_intelligence_name,
  agent_name,
  token_credits,
  tokens
FROM snowflake.account_usage.snowflake_intelligence_usage_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY start_time DESC;

-- Cortex Agent usage
SELECT
  start_time,
  end_time,
  user_name,
  agent_name,
  token_credits,
  tokens
FROM snowflake.account_usage.cortex_agent_usage_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY start_time DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Shareback requires `manifest_version: 2` + specific privileges (`CREATE SHARE`, `CREATE LISTING`). | Older apps/manifests will need migration. | Confirm in our app manifest and test install/upgrade path. |
| LISTING app specs have constraints (1 spec per listing; listing name can’t change once set). | Provider-side versioning strategy needs to avoid rename patterns. | Prototype with a dummy app + upgrade scenario. |
| New `ACCOUNT_USAGE` AI views are **Preview**. Schema/latency may change. | Dashboards/alerts may break; latency may not meet near-real-time needs. | Test in a non-prod account; track doc changes. |
| IAC is Preview and requires consumer approvals/handshake. | UX friction; needs careful workflow + documentation. | Build a minimal IAC demo + Snowsight approval guide. |

## Links & Citations

1. Release notes overview (shows Feb 2026 Native Apps updates): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 10, 2026 — Native Apps Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. Shareback docs — Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
4. Feb 13, 2026 — Native Apps Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
5. IAC docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
6. Feb 18, 2026 — New `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
7. View ref — `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/snowflake_intelligence_usage_history_view
8. Feb 18, 2026 — New `CORTEX_AGENT_USAGE_HISTORY` (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-cortex-agent-usage-history-view
9. View ref — `CORTEX_AGENT_USAGE_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/cortex_agent_usage_history

## Next Steps / Follow-ups

- Decide whether our Native App should implement Shareback for (a) provider support diagnostics and/or (b) fleetwide benchmarks.
- Prototype an IAC “FinOps interface” package (server app) + a lightweight “client app” to validate workflow + Snowsight UX.
- Add a FinOps module for AI spend attribution using the two new `ACCOUNT_USAGE` views (preview).