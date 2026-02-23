# Research: Native Apps - 2026-02-23

**Time:** 0447 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Application configuration (Preview)**: Native Apps can define configuration keys and request configuration values from the consumer (e.g., external URL, account identifier, "server app" name for inter-app communication). Config values can be marked **sensitive** to reduce exposure (e.g., protect values from query history and command output). (Feb 20, 2026)
2. **Inter-app communication (Preview)**: Native Apps can securely communicate with other apps in the same account, enabling sharing/merging of data between apps installed in the consumer account. (Feb 13, 2026)
3. **Shareback (GA)**: Native Apps can request consumer permission to share data back to the provider (or designated third parties) via a governed channel. This is now generally available. (Feb 10, 2026)
4. **Sharing Streamlit in Snowflake apps (Preview)**: Streamlit in Snowflake apps can be shared using app-builder/app-viewer URLs; access can be restricted to Streamlit apps only (block other parts of Snowflake). (Feb 16, 2026)

## Snowflake Objects & Data Sources

No new ACCOUNT_USAGE/ORG_USAGE objects were referenced directly in these notes; these updates are primarily **Native App Framework capabilities** (configuration + app-to-app communication + shareback workflows + Streamlit sharing).

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (TBD) Application configuration storage | Framework-managed | Native Apps docs | Need to confirm what is persisted, where, and what is visible to consumers/providers (and what lands in query history). |
| (TBD) Inter-app communication primitives | Framework-managed | Native Apps docs | Need to confirm the exact objects/APIs involved (e.g., which app owns the shared objects, security boundaries, and auditing surfaces). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Provider-managed “initial configuration” flow** in the FinOps Native App using *application configuration*: prompt the consumer for required values (e.g., preferred warehouse, cost attribution tags/policies, optional external FinOps endpoint). Mark secrets (API keys/tokens) as **sensitive**.
2. **Composable app ecosystem**: use *inter-app communication* to integrate with a separate “Telemetry/Observability” Native App (or other internal apps) in the same consumer account, so FinOps can read enriched signals without additional external plumbing.
3. **Telemetry shareback as a first-class feature (GA path)**: implement a “Share diagnostics back to provider” toggle backed by the *shareback* permission request. This unlocks: opt-in aggregated cost telemetry, anonymous feature usage, and support bundles.
4. **Streamlit distribution option**: if we ship Streamlit dashboards, explore *app-viewer URLs* for consumers, and optionally hard-restrict users to Streamlit-only surfaces for safer consumption.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### [Artifact Name]

```sql
-- Example SQL draft
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| "Sensitive" configuration values are *not* exposed in query history/command output, but the exact remaining exposure surface (logs, UI, provider visibility) is unclear from release notes alone. | Security posture depends on the details; could affect whether we store tokens in config vs alternate approaches. | Read the "Application configuration" doc; test in a scratch consumer account and inspect query history + SHOW output + Snowsight. |
| Inter-app communication semantics (what can be shared, permission model, auditing, and failure modes) are not described in depth in release notes. | Could block the “ecosystem” strategy if it’s more limited than expected. | Read the inter-app comms doc; prototype minimal producer/consumer apps. |
| Shareback being GA suggests stability, but Marketplace review/UX implications (how permissions are presented, revocation, etc.) may affect product design. | UX + compliance requirements; support burden if revocation breaks features. | Read the shareback doc; map to app listing requirements; add automated health checks for shareback grants. |
| Streamlit sharing (Preview) may have constraints around identity/session, and consumer restrictions might not fit all enterprise patterns. | Might be a nice-to-have rather than core UI strategy. | Read Streamlit sharing doc; validate restrictions in an enterprise-like role model. |

## Links & Citations

1. Release note (Feb 20, 2026) — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Release note (Feb 13, 2026) — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Release note (Feb 10, 2026) — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Release note (Feb 16, 2026) — Sharing Streamlit in Snowflake apps (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-16-sis
5. Release notes index (for context): https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Pull and read the linked docs pages (app configuration, inter-app communication, shareback specs, Streamlit sharing) and extract: required privileges, SQL/API surface, auditing visibility, and lifecycle/revocation behavior.
- Decide whether we treat **application configuration** as our canonical “consumer-provided settings store” (and what we *must not* put there).
- Add an “opt-in telemetry shareback” work item to the FinOps Native App roadmap (now that the capability is GA).

