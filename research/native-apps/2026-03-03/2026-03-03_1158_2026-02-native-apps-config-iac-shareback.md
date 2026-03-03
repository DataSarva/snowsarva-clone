# Research: Native Apps - 2026-03-03

**Time:** 1158 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Native Apps can request configuration values from consumers** via *application configurations* (Preview as of Feb 20, 2026). These config keys can include things like an external URL/account identifier or the name of another server app to support inter-app communication. Config values can be marked **sensitive** to reduce exposure in query history and command output. 
2. **Native Apps can securely communicate with other apps in the same account** (Inter-App Communication, Preview as of Feb 13, 2026). The intent is to enable apps to share/merge data within the consumer account.
3. **Native Apps can request permission to “share back” data** to the provider or designated third parties (Shareback, **GA** as of Feb 10, 2026). This provides a governed channel for telemetry/analytics/compliance-style data exchange.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Application configurations | Native App framework feature | Snowflake docs (developer guide) | Exact object model/DDL not captured in release note excerpt; follow docs to map to DDL + permissions. |
| Inter-app communication | Native App framework feature | Snowflake docs (developer guide) | Need to confirm how apps authenticate/authorize across app boundaries (roles/privileges, server app naming, etc.). |
| Shareback (request data sharing with app specifications) | Native App framework feature | Snowflake docs (developer guide) | Ties to app specs/listings + consumer-granted permissions. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Config-driven install/activation wizard for the FinOps Native App**
   - Define required config keys (e.g., “admin warehouse name”, “alert webhook URL”, “telemetry shareback toggle”).
   - Mark secrets as sensitive.
   - UX: show “missing/invalid config” gating to avoid partial installs.
2. **Pluggable integration layer using Inter-App Communication (Preview)**
   - Allow the FinOps app to read/enrich from other apps in-account (e.g., governance/observability apps) when present.
   - Start with a single optional integration: “if other app X configured, pull Y.”
3. **First-class telemetry shareback channel (GA)**
   - Offer a provider-facing shareback dataset: anonymized feature usage + cost signals.
   - Make it opt-in, clearly documented, and minimal.

## Concrete Artifacts

### Artifact: Proposed configuration key set (draft)

```text
APP_CONFIG_KEYS (draft)
- FINOPS__ADMIN_WAREHOUSE (string)
- FINOPS__BUDGET_DB (string)
- FINOPS__ALERT_TARGET (string; e.g., email/webhook identifier)
- FINOPS__TELEMETRY_SHAREBACK_ENABLED (boolean)
- FINOPS__TELEMETRY_TOKEN (sensitive string)
- FINOPS__INTEGRATION__SERVER_APP_NAME (string; for inter-app comm)
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Sensitive” configuration values meaningfully reduce exposure beyond query history/command output | Might still leak through other channels (logs, downstream tables, screenshots) if mishandled in app code | Read full “Application configuration” docs and test value visibility in QUERY_HISTORY + result caching + app logs. |
| Inter-app communication security model (privileges/role boundaries) is compatible with least-privilege app design | Could require broader grants than desired, complicating deployment | Review “Inter-app Communication” docs; prototype minimal cross-app call path in a dev account. |
| Shareback GA implies stable APIs/behavior for production telemetry | If assumptions wrong, telemetry pipeline could break or require frequent updates | Read shareback docs, confirm versioning/contract, and implement with feature flag + schema evolution strategy. |

## Links & Citations

1. Snowflake release note — Native Apps: Configuration (Preview), Feb 20, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Snowflake release note — Native Apps: Inter-App Communication (Preview), Feb 13, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Snowflake release note — Native Apps: Shareback (GA), Feb 10, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Developer guide — Application configuration: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
5. Developer guide — Inter-app Communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull the *Application configuration* docs and extract the exact DDL / privilege model; convert into an ADR for our FinOps app.
- Prototype a minimal inter-app integration with a “toy” app pair to confirm authz + data exchange patterns.
- Design an opt-in shareback schema for telemetry that does not contain sensitive customer identifiers.
