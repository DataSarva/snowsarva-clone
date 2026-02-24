# Research: Native Apps - 2026-02-24

**Time:** 04:54 UTC  
**Topic:** Snowflake Native App Framework (FinOps/telemetry-enabling capabilities)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Application configurations (Preview)** let a Snowflake Native App define configuration keys and request values from the consumer (examples called out: server app name for inter-app comms; arbitrary strings like external URL/account identifier). Config keys can be marked **sensitive** to reduce exposure (e.g., API keys/tokens not shown in query history / command output). (Feb 20, 2026)
2. **Inter-App Communication (Preview)** enables Snowflake Native Apps to securely communicate with other apps in the same consumer account, enabling sharing/merging data across apps. (Feb 13, 2026)
3. **Shareback (GA)** allows apps to request consumer permission to share data back to the provider or designated third parties; release notes explicitly position this for compliance reporting, telemetry/analytics sharing, and preprocessing via a governed exchange channel. (Feb 10, 2026)
4. **Sharing Streamlit in Snowflake apps (Preview)** supports sharing Streamlit in Snowflake apps via app-builder/app-viewer URLs and can restrict users to only access Streamlit apps (block access to other Snowflake areas). (Feb 16, 2026)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (TBD) | (TBD) | Release notes | These updates are framework/product capabilities; no new ACCOUNT_USAGE/ORG_USAGE objects were referenced in the release notes excerpts. Follow-up needed to see if any new views/events exist for shareback/config lifecycle. |

## MVP Features Unlocked

1. **Provider-side telemetry pipeline via Shareback (GA):** implement an optional “Send Usage/Cost Telemetry” feature that, when enabled by the consumer, shares aggregated cost/usage signals back to the provider for fleet-level insights.
2. **Zero-copy integration setup via App Configuration (Preview):** prompt for consumer-specific identifiers/URLs (e.g., external CMDB, billing account ids, webhook endpoints) without hardcoding; store as sensitive config when needed.
3. **Composable FinOps suite via Inter-App Communication (Preview):** design Mission Control as a “hub app” that can ingest/export normalized cost signals to other native apps in the same account (or consume signals from a “collector” app).

## Concrete Artifacts

### Draft: configuration key schema (conceptual)

```text
config_keys:
  - key: external_billing_account_id
    type: string
    sensitive: false
  - key: webhook_url
    type: string
    sensitive: false
  - key: provider_telemetry_token
    type: string
    sensitive: true
  - key: finops_server_app_name
    type: string
    sensitive: false
```

### Draft: shareback consent UX (conceptual)

- Toggle: “Enable governed shareback telemetry to provider”
- Explain: what’s shared (aggregated warehouse spend / query cost hotspots), how often, and how to revoke.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Sensitive” app configuration values are fully protected in all relevant surfaces (query history, SHOW output, logs) | Potential leakage of secrets if misunderstood | Read the app configuration docs; test in a real account for query history / UI surfaces. |
| Inter-App Communication and App Configuration are Preview and may have breaking changes | Feature volatility | Track release notes + check doc updates; gate in product behind feature flags. |
| Shareback GA still requires careful scoping of what data is shared to avoid privacy/compliance issues | Legal/security risk | Define a minimal schema and opt-in; provide revocation + auditability. |

## Links & Citations

1. Feb 20, 2026: Snowflake Native Apps: Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Feb 13, 2026: Snowflake Native Apps: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Feb 10, 2026: Snowflake Native Apps: Shareback (General Availability) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Feb 16, 2026: Sharing Streamlit in Snowflake apps (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-16-sis

## Next Steps / Follow-ups

- Read the linked docs pages for:
  - exact SQL/API surface for app configuration (DDL/commands, access control, how consumers set values)
  - exact primitives for inter-app communication (permissions, supported data exchange patterns)
- Decide: Mission Control architecture — single app vs. hub + satellite apps using inter-app comms.
- Prototype: shareback telemetry schema + opt-in flows for cost/usage analytics.
