# Research: Native Apps - 2026-02-25

**Time:** 1102 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps: Shareback is GA (Feb 10, 2026).** Providers can request consumer permission to share data back to the provider or designated third parties via app specifications; intended for compliance reporting, telemetry/analytics, and data preprocessing use cases.
2. **Native Apps: Inter-App Communication is Preview (Feb 13, 2026).** Native apps can securely communicate with other apps in the same consumer account to enable sharing/merging data across apps.
3. **Native Apps: Configuration is Preview (Feb 20, 2026).** Apps can request configuration values from consumers using application configurations; configuration keys can be marked **sensitive** to protect values (e.g., API keys/tokens) from exposure in query history and command output.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| Application configuration (feature) | Native App Framework capability | Snowflake release notes | Lets provider define config keys; consumer provides values; can mark values sensitive. Exact DDL/SDK surface area to confirm in docs. |
| App specifications (for Shareback) | Native App Framework capability | Snowflake release notes | Shareback permissioning is requested via app specification(s). Need to confirm manifest/app-spec schema fields. |
| Inter-app communication (feature) | Native App Framework capability | Snowflake release notes | Enables secure comms between apps in same account; likely governed by app-level privileges/roles. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“Bring-your-own-Integrations” setup UX without brittle post-install steps** (Preview):
   - Use *application configurations* to request consumer-provided values needed for integrations (e.g., a webhook URL, account identifier, or “name of companion app/service”).
   - Mark secrets as **sensitive** to reduce accidental leakage into query history/log output.
   - Product impact for our FinOps Native App: easier onboarding for things like alert destinations, policy toggles, or external correlation IDs.

2. **Composable “FinOps platform” approach with multiple apps** (Preview):
   - Use **Inter-App Communication** so a small “FinOps Core” app can securely exchange signals/data with specialized apps (e.g., “Cost Anomalies”, “Warehouse Optimizer”, “Governance Advisor”) installed in the same account.
   - Potential: avoid shipping one giant monolith; let customers install only modules they need.

3. **First-class telemetry/feedback loop from consumer → provider** (GA):
   - Use **Shareback** to request permission for sending aggregated usage/health metrics back to the provider (or an agreed third party) for:
     - proactive support (failed jobs, stale configs),
     - improving recommendations (which optimizations are accepted/ignored),
     - compliance reporting.

## Concrete Artifacts

### Draft: configuration keys we likely want (provider-defined)

*(Not yet validated against the exact config schema; treat as product design input.)*

- `ALERT_DESTINATION` (string) — Slack webhook / Teams webhook / email routing key
- `BUDGET_OWNER` (string) — team name / cost center
- `ORG_ACCOUNT_NAME` (string) — for org-level rollups when applicable
- `PROVIDER_TELEMETRY_OPT_IN` (boolean)
- `PROVIDER_TELEMETRY_SHARE` (shareback permission scope)

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| “Sensitive” config values are truly protected end-to-end (not just masked in some surfaces). | Possible accidental secret disclosure. | Confirm how Snowflake enforces non-exposure (query history, SHOW/DESCRIBE output, logs). |
| Inter-app comms privilege model could be restrictive or require extra consumer steps. | Limits modular architecture / increases onboarding friction. | Read Inter-app Communication docs; test minimal PoC with two apps. |
| Shareback scopes/controls may be narrow or require Marketplace/Provider Studio constraints. | Telemetry feature may be harder to ship broadly. | Validate app-spec fields and operational constraints; test in a provider+consumer sandbox. |

## Links & Citations

1. Snowflake Native Apps: **Shareback (GA)** (Feb 10, 2026) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Snowflake Native Apps: **Inter-App Communication (Preview)** (Feb 13, 2026) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Snowflake Native Apps: **Configuration (Preview)** (Feb 20, 2026) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration

## Next Steps / Follow-ups

- Pull the actual docs for “Application configuration”, “Inter-app Communication”, and “Request data sharing with app specifications” and extract:
  - the exact DDL/manifest/app-spec structures,
  - consumer UX flows in Snowsight,
  - any edition/region/preview constraints.
- Decide which of these features are worth adopting immediately (Shareback seems immediately actionable; the other two are Preview and may need guardrails/feature flags).
