# Research: Native Apps - 2026-02-24

**Time:** 2259 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps: Shareback is GA (Feb 10, 2026).** A Snowflake Native App can request permission from a consumer to share data back with the provider (or designated third parties), enabling governed telemetry/compliance reporting flows. 
2. **Native Apps: Inter-App Communication is in Preview (Feb 13, 2026).** Native apps can securely communicate with other apps in the same consumer account to share/merge data across apps.
3. **Native Apps: Application Configuration is in Preview (Feb 20, 2026).** Apps can define configuration keys and request values from consumers; values can be marked **sensitive** to reduce exposure (e.g., avoid query history/command output exposure).
4. **Owner’s-rights contexts now allow more introspection (release 10.3, Feb 02–05, 2026).** For owner’s-rights stored procedures / Native Apps / Streamlit, most `SHOW`/`DESCRIBE` commands are now permitted and `INFORMATION_SCHEMA` views/table functions are accessible, with some history-function exceptions remaining restricted.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (App configuration keys/values) | Native Apps object(s) | Native Apps: Configuration (Preview) | Exact DDL/object names not captured in the release note; see linked doc “Application configuration”. |
| (Inter-app communication primitives) | Native Apps capability | Native Apps: Inter-App Communication (Preview) | Exact primitives not captured in the release note; see linked doc “Inter-app Communication”. |
| `INFORMATION_SCHEMA.*` | Views/TVFs | 10.3 release notes | Newly accessible from owner’s-rights contexts (with exceptions). |
| `SHOW ...` / `DESCRIBE ...` | Commands | 10.3 release notes | Broadly allowed from owner’s-rights contexts (with exceptions). |

## MVP Features Unlocked

1. **Provider telemetry pipeline via Shareback (GA):** Add an optional “Send diagnostics / usage metrics” workflow where the consumer explicitly grants Shareback, and we periodically share back aggregated cost + performance telemetry (safe defaults, least-privileged).
2. **First-class “App Setup” UX using Application Configuration (Preview):** Replace brittle “paste account locator / URL / token” steps with config keys (mark secrets sensitive) and validate values during install/upgrade.
3. **Composable multi-app suite (Preview):** Use Inter-App Communication to split “core cost extraction” and “advanced insights/automation” into separate apps that can cooperate inside a single account (clear boundaries + upgrade paths).

## Concrete Artifacts

### Implementation sketch: configuration-driven setup

- Define configuration keys for:
  - upstream server app name (for IAC)
  - external webhook base URL (if used)
  - optional API token / secret (marked sensitive)
- On setup/upgrade, read configuration values and:
  - run validation (format checks, reachability checks if applicable)
  - store derived non-secret settings in app-owned tables
  - never echo sensitive values in logs

### Implementation sketch: Shareback consent model

- Surface a “Diagnostics sharing” toggle in UI.
- If enabled:
  - request Shareback permission
  - share back only **aggregated** facts (e.g., daily warehouse credits by tag / cost center) unless explicitly expanded
  - include a “revoke” path and document data categories

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview features (IAC + Configuration) may change or require specific account editions/regions. | Could break install/upgrade flows if we depend on them. | Validate in dev accounts; gate usage with feature detection + fallback path. |
| “Sensitive configuration” guarantees/behavior details aren’t fully specified in the release note. | Risk of accidental secret exposure (query history, logs). | Read full “Application configuration” doc; test what appears in query history + command output. |
| Owner’s-rights introspection still has exceptions (history functions). | Some diagnostics queries may still be blocked. | Confirm allowed `SHOW`/`DESCRIBE` set and usable `INFORMATION_SCHEMA` objects in app context. |

## Links & Citations

1. Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Application Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. 10.3 release notes (owner’s-rights introspection expansion): https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Read the linked deep docs for “Inter-app Communication” + “Application configuration” and capture:
  - concrete object names, DDL patterns, and required grants
  - how sensitive config behaves in query history + SHOW output
- Decide if we gate Preview features behind an app capability flag until GA.
