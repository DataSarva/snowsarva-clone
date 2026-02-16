# Research: Native Apps - 2026-02-16

**Time:** 03:33 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-App Communication (Preview)**: Snowflake Native Apps can securely communicate with other native apps in the same account, enabling apps to share and merge data across apps within a consumer account. (Preview) 
2. **Shareback (GA)**: A native app can request permission from consumers to share data back to the provider or designated third parties via a governed channel; intended use cases include compliance reporting, telemetry/analytics sharing, and data preprocessing. (General Availability)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| *(TBD — depends on IAC + Shareback implementation)* | | | Release notes describe capabilities but not the concrete system views/events surfaced. Validate what objects are created/accessible when enabling IAC + shareback in a test account. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“FinOps Hub” companion app** (Preview-gated): a small Native App that focuses on cost/ops intelligence (rules, recommendations, anomaly outputs) and can **interoperate with multiple other apps** in the same consumer account via Inter-App Communication—acting as a shared service.
2. **Provider-side telemetry pipeline** (GA): implement an opt-in shareback flow so customers can allow the app to share **operational metrics / usage aggregates / configuration posture** back to the provider for benchmarking + proactive support.
3. **Cross-app governance & data exchange patterns**: standardize a “shared tables contract” (schemas + semantic model) that multiple apps can merge into, enabling composability (e.g., FinOps app + Observability app share a common dataset).

## Concrete Artifacts

### Draft: Shareback data contract (provider telemetry)

```sql
-- Sketch only (objects TBD): minimal, privacy-preserving telemetry aggregates.
-- Goal: never ship raw query text or PII by default.

-- Example payload columns (aggregate grain: day, warehouse, cost center tag)
--   event_date
--   warehouse_name
--   service_type
--   credits_used
--   query_count
--   bytes_scanned
--   app_version
--   feature_flags
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-App Communication is **Preview** and may require enablement / may change APIs. | Feature may not be available broadly; implementation churn. | Read the IAC developer docs; confirm feature flags/regions/editions; run a POC. |
| Shareback permissions + destination mechanics (provider vs 3rd party) are not fully specified in the release note excerpt. | Could constrain telemetry architecture (e.g., only to provider account, or via specific listing/spec workflow). | Read “Request data sharing with app specifications” doc and confirm end-to-end flow in Marketplace listing. |
| Concrete system tables/views for auditing shareback + IAC are unknown. | Hard to build governance/observability features without identifying metadata sources. | Identify and document any ACCOUNT_USAGE/INFO_SCHEMA objects created for these features in a test environment. |

## Links & Citations

1. Release note: **Inter-App Communication (Preview)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Release note: **Shareback (GA)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. Inter-app Communication docs — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
4. Shareback docs entry point (“Request data sharing with app specifications”) — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Pull and summarize the two linked developer-doc pages (IAC + shareback) into a follow-on note with concrete APIs + security model.
- Define a minimal shareback telemetry schema for a FinOps native app (aggregates, no PII) + an explicit customer opt-in UX.
- Decide if we want a multi-app architecture: a small “FinOps Core” app + optional companion apps using IAC for composability.
