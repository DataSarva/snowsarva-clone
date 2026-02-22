# Research: Native Apps - 2026-02-22

**Time:** 0427 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. (Preview) Native Apps can define **application configuration keys** to request values from consumers (e.g., external URL, account identifier, name of a “server app” used for inter-app communication). Values can be marked **sensitive** to avoid exposure in query history and command output. 
2. (Preview) Native Apps can perform **inter-app communication** with other Native Apps in the same consumer account, enabling secure data sharing/merging across apps.
3. (GA) Native Apps can use **Shareback** to request consumer permission to share data back to the provider (or designated third parties) via a governed channel.
4. (Preview) Streamlit in Snowflake apps can be shared via **app-builder** or **app-viewer** URLs, and can be restricted so users can access only Streamlit apps (not other Snowflake areas).

## Snowflake Objects & Data Sources

No new ACCOUNT_USAGE / ORG_USAGE objects were introduced by these Native Apps features (these are framework capabilities). Relevant “objects” here are **Native App framework constructs** (configuration keys, inter-app channels, shareback specifications) rather than usage views.

| Object/Construct | Type | Source | Notes |
|---|---|---|---|
| Application configuration (keys/values, sensitive values) | Native App framework feature (Preview) | Docs | Used for consumer-provided values (URLs, identifiers, app names); can be marked sensitive. |
| Inter-app communication | Native App framework feature (Preview) | Docs | Secure communication between apps in same account; can be combined with configuration to reference counterpart app(s). |
| Shareback / requesting app specifications | Native App framework feature (GA) | Docs | Consumer grants permission to share specific datasets back to provider/third parties. |
| Streamlit app sharing (app-builder/app-viewer URLs) | Streamlit in Snowflake feature (Preview) | Docs | Potential distribution surface for lightweight UIs. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Consumer configuration-driven onboarding**: add an onboarding flow that reads app configuration keys (e.g., `EXTERNAL_TELEMETRY_URL`, `CUSTOMER_ACCOUNT_ID`, `BUDGET_OWNER_EMAIL`) instead of hardcoding/SQL variables; treat secrets as *sensitive configs*.
2. **Composable “platform suite” mode**: implement optional inter-app integration points (e.g., our FinOps app can discover/accept data from a companion Governance/Observability app via inter-app comm). Use configuration to let the consumer specify the companion app name(s).
3. **Telemetry/analytics shareback package** (now GA): offer an opt-in “Send anonymized usage + cost signals to provider” shareback spec, enabling cross-customer benchmarking and proactive tuning recommendations.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Proposed configuration keys (draft)

```text
# Public (non-sensitive)
CUSTOMER_ACCOUNT_ID
BILLING_ENTITY
TELEMETRY_MODE           # off|minimal|full
COMPANION_APPS           # comma-separated app names or JSON list

# Sensitive
EXTERNAL_TELEMETRY_URL
API_KEY
OAUTH_CLIENT_SECRET
```

### Shareback payload concept (draft)

```text
Dataset: APP_USAGE_SUMMARY_DAILY
- date
- account_locator (hashed)
- total_credits
- top_warehouses_by_credits (top-N, hashed names)
- query_patterns (coarse buckets)

Notes:
- Implement only after validating shareback mechanics + review data minimization.
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| “Sensitive configuration” guarantees (exact redaction behavior, surfaces affected) need verification. | Could leak secrets if misunderstood. | Read full *Application configuration* docs + test in dev account: query history, SHOW output, UI surfaces. |
| Inter-app communication scope/permissions unclear from release note excerpt (e.g., allowed operations, auth model). | Might constrain integration design. | Read full *Inter-app Communication* docs + build a minimal PoC with two apps. |
| Shareback governance details (what can be shared, provider/third-party routing, consent UX) not fully captured here. | Risk of over-promising telemetry features. | Read full *requesting app specs/listing* docs; confirm Marketplace review constraints. |
| Streamlit sharing might not be a fit for Native App UI packaging depending on consumer restrictions. | UI approach risk. | Validate Streamlit sharing URLs + access restriction behavior in customer-like environment. |

## Links & Citations

1. Feb 20, 2026: Native Apps — Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Application configuration docs: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Feb 13, 2026: Native Apps — Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Inter-app Communication docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
5. Feb 10, 2026: Native Apps — Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
7. Feb 16, 2026: Sharing Streamlit in Snowflake apps (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-16-sis
8. Sharing Streamlit in Snowflake apps docs: https://docs.snowflake.com/en/developer-guide/streamlit/features/sharing-streamlit-apps

## Next Steps / Follow-ups

- Skim the full *Application configuration* doc and capture specifics: how keys are defined, how values are read at runtime, and the exact semantics of “sensitive” redaction.
- Prototype an inter-app comm PoC: App A publishes a small table/view; App B requests + merges it; document required privileges and failure modes.
- Design a “Telemetry Shareback” spec with strict minimization + opt-in toggles; validate Marketplace/policy constraints.

