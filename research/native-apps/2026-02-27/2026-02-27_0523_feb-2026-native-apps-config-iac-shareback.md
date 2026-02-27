# Research: Native Apps - 2026-02-27

**Time:** 0523 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “Shareback” is GA (Feb 10, 2026):** apps can request consumer permission to share data back to the provider (or designated third parties) via a governed mechanism. 
2. **Inter-App Communication is Preview (Feb 13, 2026):** Native Apps in the same consumer account can securely communicate, enabling apps to share/merge data across apps.
3. **Application Configuration is Preview (Feb 20, 2026):** apps can define configuration keys to request values from consumers; configuration values can be marked **sensitive** so they aren’t exposed in query history / command output.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| *(unknown: config storage / metadata)* | *(unknown)* | Docs | Release note references “application configurations” + sensitive value handling; need to inspect docs for any new DDL/SHOW/DESCRIBE and system views. |
| *(shareback / app specs objects)* | *(unknown)* | Docs | Shareback is described via “request permission… using app specifications” docs; need to enumerate the concrete objects / privileges involved. |

**Notes / TODO for follow-up validation**
- Pull the linked docs and extract the concrete primitives (DDL, grants/privileges, views, procedures) so we can wire this into the Native App.

## MVP Features Unlocked

1. **Provider telemetry shareback (GA path):** implement an optional “Share diagnostics back to vendor” toggle that (a) creates a governed shareback channel and (b) sends aggregated cost/perf metrics + anonymized configuration. Useful for managed onboarding + support.
2. **Composable “FinOps hub” via inter-app comm (Preview):** design an integration point where our app can accept (or provide) a standardized dataset to/from other internal apps (e.g., governance app, data quality app) inside the same consumer account.
3. **First-class external integrations config UX (Preview):** replace brittle “enter this into a table / secret” setup with app configuration keys, including **sensitive** keys for API tokens, endpoints, org identifiers.

## Concrete Artifacts

### Proposed configuration schema (app-level)

- Keys:
  - `TELEMETRY_SHAREBACK_ENABLED` (bool)
  - `TELEMETRY_TARGET` (enum: provider | third_party)
  - `EXTERNAL_ALERTS_WEBHOOK_URL` (string, sensitive)
  - `CLOUD_BILLING_ACCOUNT_ID` (string)

*(Exact implementation depends on docs; this is a design sketch.)*

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Preview features (IAC + Configuration) may change APIs/privileges. | Rework risk if we build tightly to preview semantics. | Track doc diffs + re-check at GA. |
| “Sensitive configuration” guarantees are as described (no exposure in query history/command output). | If leaky, could violate security posture. | Verify behavior empirically + check docs for exceptions. |
| Shareback mechanics require Marketplace listing/app spec workflow changes. | May impact packaging + release pipeline. | Read “requesting app specs listing” docs and map to our delivery model. |

## Links & Citations

1. Shareback GA release note (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Inter-App Communication (Preview) release note (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Configuration (Preview) release note (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Application configuration docs (linked from release note): https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
5. Inter-app communication docs (linked from release note): https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull + summarize the two linked doc pages into a follow-up note (extract concrete SQL, privileges, system views).
- Decide whether to:
  - ship Shareback-based provider telemetry first (GA), and
  - treat configuration/IAC as “design now, implement behind feature flag” until GA.
