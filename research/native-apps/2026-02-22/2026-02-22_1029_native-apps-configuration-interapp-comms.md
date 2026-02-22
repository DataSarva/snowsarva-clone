# Research: Native Apps - 2026-02-22

**Time:** 10:29 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps can request configuration values from consumers using **application configurations** (Preview). These configurations can include keys for values like an external URL, account identifier, or the name of another app used for inter-app communication. Config values can be marked **sensitive** to protect secrets from exposure in query history and command output. 
2. Snowflake Native Apps can **securely communicate with other apps in the same account** via **Inter-App Communication** (Preview), enabling sharing/merging data across multiple apps installed in a consumer account.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (TBD: configuration storage / access surface) | N/A | Release notes | Snowflake docs describe the capability; specific SQL objects/APIs were not captured in the excerpts we pulled. Validate exact DDL/SQL/API surface in “Application configuration” + “Inter-app Communication” docs. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Native App “Configuration Wizard” (consumer-side):** on first run, prompt for required keys (e.g., “finops_control_plane_url”, “org_name”, “cost_center_tag_key”, “alert_webhook_url”) and store them via application configuration; mark secrets as sensitive so they don’t leak in query history.
2. **Composable FinOps app integration:** leverage inter-app communication to optionally ingest signals from other native apps (e.g., governance/classification apps) and enrich cost insights without requiring external egress.
3. **Provider-safe upgrades:** move environment-specific values (URLs, identifiers, integration toggles) out of setup scripts into configuration, reducing patch churn and making upgrades less brittle.

## Concrete Artifacts

### Proposed config key schema (draft)

```yaml
# conceptual schema (exact Snowflake syntax TBD)
required:
  - key: FINOPS_CONTROL_PLANE_URL
    type: string
    sensitive: false
  - key: FINOPS_API_TOKEN
    type: string
    sensitive: true
optional:
  - key: COST_CENTER_TAG_KEY
    type: string
    sensitive: false
  - key: SERVER_APP_NAME
    type: string
    sensitive: false
    note: "For inter-app communication"
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact SQL/API surface for “application configuration” is not yet validated from primary reference docs (only release note excerpt). | We might design UI/installer flow incorrectly. | Read and capture details from the “Application configuration” reference page; confirm how values are set/read, RBAC, and how “sensitive” behaves in practice. |
| Inter-app communication security model (permissions/allowlist/manifest requirements) not yet validated. | Integration design could be blocked by required privileges/consent flows. | Pull and summarize the “Inter-app Communication” docs; map to manifest + consumer consent UX. |

## Links & Citations

1. Feb 20, 2026: **Snowflake Native Apps: Configuration (Preview)** — https://docs.snowflake.com/release-notes/2026/other/2026-02-20-nativeapps-configuration
2. Feb 13, 2026: **Snowflake Native Apps: Inter-App Communication (Preview)** — https://docs.snowflake.com/release-notes/2026/other/2026-02-13-nativeapps-iac

## Next Steps / Follow-ups

- Pull the underlying reference docs linked from the release notes (“Application configuration”, “Inter-app Communication”) and capture: exact commands/APIs, privilege model, and any limitations.
- Decide whether Mission Control’s Native App should prefer configuration (vs secrets in tables/stages) for external URLs/tokens.
