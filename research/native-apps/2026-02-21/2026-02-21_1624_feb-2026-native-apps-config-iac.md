# Research: Native Apps - 2026-02-21

**Time:** 1624 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Application configuration (Preview)** lets a Native App **request configuration values from the consumer** via defined configuration keys (e.g., a server app name for inter-app communication, external URL, account identifier). Values can be **marked sensitive** so they are protected from exposure in **query history and command output**. 
2. **Inter-App Communication (Preview)** lets Snowflake Native Apps **securely communicate with other apps in the same account**, enabling sharing/merging data across apps in a single consumer account.
3. These two features combine: configuration can hold **connection/target identifiers** (and potentially secrets) required to bootstrap inter-app workflows without hardcoding or asking users to run manual SQL per environment.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Native App *application configuration* keys/values | Native App framework object (TBD) | Snowflake docs | Exact DDL/object model not captured in release note; needs follow-up in “Application configuration” developer guide. |
| Inter-app communication endpoints/identity | Native App framework concept | Snowflake docs | Likely requires consumer-granted permissions + explicit allowed peers; validate security model in developer guide. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Zero-touch onboarding wizard for multi-app deployments:** in the Admin/Installer UI, collect required environment values (URLs, account ids, “peer app name”) → write them into app configuration keys. No more “paste this SQL” steps.
2. **Secure secret handoff pattern:** store API keys/tokens as **sensitive** configuration values (instead of plaintext parameters), and only materialize them into runtime where needed. Validate the exact exposure guarantees (query history, SHOW output) before relying on it.
3. **Composable FinOps suite:** let a “core telemetry/cost” app and “workload advisor” app exchange summarized metrics via inter-app communication so features can ship as smaller apps without losing cross-feature insights.

## Concrete Artifacts

### Draft: App configuration key design (proposed)

- `CONFIG.PEER_APP_NAME` (string) — target server app for inter-app communication
- `CONFIG.EXTERNAL_API_BASE_URL` (string)
- `CONFIG.EXTERNAL_API_TOKEN` (sensitive string)

> Follow-up: confirm naming constraints + whether configs are namespaced, versioned, and readable by which roles.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Sensitive” configs fully prevent secret leakage beyond query history/command output (e.g., UI logs, events) | Security risk if not comprehensive | Read developer guide details; test by setting config and checking ACCESS_HISTORY/QUERY_HISTORY/SHOW output in a scratch account. |
| Inter-app comm permission model is sufficiently strict and auditable | Data exfiltration concerns | Read inter-app comm docs; identify required grants + any audit trails. |
| Config APIs are stable enough to build onboarding around (Preview) | Rework risk | Track release notes for GA; isolate config integration behind an interface. |

## Links & Citations

1. Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Application configuration developer guide: https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
3. Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Inter-app communication developer guide: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull the developer-guide pages and extract the exact DDL/APIs (what objects exist, read/write semantics, role requirements).
- Prototype a minimal “config-driven inter-app handshake” between two demo apps to validate ergonomics and auditability.
