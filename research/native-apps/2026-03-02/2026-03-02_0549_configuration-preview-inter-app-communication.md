# Research: Native Apps - 2026-03-02

**Time:** 0549 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Native Apps can request **configuration values** from consumers using **application configurations**. (Preview, Feb 20 2026)
2. Configuration keys can request consumer-provided values like a server app name for inter-app communication, arbitrary string values (URL/account id), and can be marked **sensitive** to reduce exposure in **query history** and **command output**. (Preview, Feb 20 2026)
3. Native Apps can now perform **inter-app communication** securely with other apps in the same account, enabling sharing/merging data across apps. (Preview, Feb 13 2026)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Application configuration (new capability) | Native App framework feature | Snowflake Release Notes + docs | Need to verify exact DDL/commands and operational behavior for “sensitive” configs. |
| Inter-app Communication | Native App framework feature | Snowflake Release Notes + docs | Preview; validate required privileges + security model. |

## MVP Features Unlocked

1. **Consumer setup wizard**: replace “paste values into a worksheet” setup steps with a formal configuration flow (URLs, account ids, integration names), reducing install friction.
2. **Secret-safe connector configs**: store API keys/tokens as *sensitive configs* (when supported) to avoid accidental leakage via query history/CLI output.
3. **Multi-app ecosystem play**: enable Mission Control to optionally interoperate with a companion “data collector” app (or third-party apps) via inter-app communication—useful for governance/observability splits.

## Concrete Artifacts

### ADR stub: “Configurations vs tables for consumer-provided settings”

- Default: non-secret settings can live in app-owned tables for audit/versioning.
- Secrets: prefer application configuration marked sensitive (when it meets requirements).
- Need a migration plan for existing installs.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Sensitive config” guarantees are summarized but not exhaustively defined | We might over-promise secrecy properties | Read full “Application configuration” docs and test: visibility in query history, role access, exports |
| Inter-app communication is Preview | Potential breaking changes; availability varies by region/account | Track GA timeline; gate feature behind capability detection |

## Links & Citations

1. Feb 20, 2026: Native Apps: Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Application configuration docs — https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Feb 13, 2026: Native Apps: Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Inter-app Communication docs — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull the exact configuration API/DDL + example for sensitive keys; add to Mission Control install/upgrade flow.
- Explore inter-app comm security model (who can call what, audit trails) before proposing a multi-app architecture.
