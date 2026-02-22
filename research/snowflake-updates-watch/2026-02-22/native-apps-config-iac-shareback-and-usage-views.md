# Snowflake Updates Watch — Native Apps Configuration + IAC + Shareback; New Account Usage View (Preview)

Date: 2026-02-22 (UTC)

## Sources (release notes)
- Snowflake Native Apps: Configuration (Preview) — Feb 20, 2026
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
- Snowflake Native Apps: Inter-App Communication (Preview) — Feb 13, 2026
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
- Snowflake Native Apps: Shareback (GA) — Feb 10, 2026
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
- ACCOUNT_USAGE: SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY (Preview) — Feb 18, 2026
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view

## What changed (high signal)
### 1) Native Apps: Application Configuration (Preview)
Native Apps can define configuration keys and request values from consumers (e.g., external URL/account identifier, server app name for inter-app comms). Config values can be marked **sensitive** to reduce exposure in query history/command output.

Doc pointer:
- https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration

### 2) Native Apps: Inter-App Communication (Preview)
Native Apps can securely communicate with other apps in the same consumer account (enables sharing/merging data across apps).

Doc pointer:
- https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

### 3) Native Apps: Shareback (GA)
Apps can request permission from consumers to share data **back** to the provider (or designated third parties) via a governed channel.

Doc pointer:
- https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

### 4) ACCOUNT_USAGE: SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY (Preview)
New ACCOUNT_USAGE view provides per-interaction credit consumption details for Snowflake Intelligence, including metadata (user ID, request ID, Intelligence ID, agent ID) and aggregated + granular tokens/credits.

Doc pointer:
- https://docs.snowflake.com/en/sql-reference/account-usage/snowflake_intelligence_usage_history_view

## Implications for a FinOps / Admin Native App
### Configuration (Preview) — operational + security win
- Enables **first-run setup** without custom UI hacks: consumer supplies values like an external webhook URL, tenant/account ID, or integration targets.
- “Sensitive” config suggests a cleaner story for **API keys/tokens** than plain SQL parameters (still verify exact guarantees: storage, role access, and auditability).

### Inter-App Communication (Preview) — modular product strategy
- Opens the door to a “platform app” that can exchange data with other installed apps.
- For FinOps: could ingest signals from governance/security apps (or a separate telemetry collector app) and combine them into cost intelligence.

### Shareback (GA) — telemetry + benchmarks
- Strong for **opt-in telemetry**: send anonymized usage/cost aggregates back to provider for benchmarking, product improvement, and compliance reporting.
- Could enable provider-run advisory services without requiring consumers to build data shares manually.

### New Intelligence usage view (Preview) — new cost surface
- If customers adopt Snowflake Intelligence heavily, this view enables **chargeback/showback** and anomaly detection for agent/tool usage credits.
- Potential feature: “AI spend dashboard” (tokens/credits per agent/user/request) + budgets/alerts.

## Follow-ups / TODO
- Read and summarize app-configuration and inter-app-communication docs for concrete objects/privileges/limitations.
- Validate how “sensitive” config values behave: masking, exposure to ACCOUNT_USAGE / QUERY_HISTORY, and role-level access.
- For Shareback GA: confirm workflows and the provider/consumer permission boundary; identify what data objects are eligible.
