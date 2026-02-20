# Research: Native Apps - 2026-02-20

**Time:** 0408 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-App Communication (Preview)** was announced on **Feb 13, 2026**, enabling Snowflake Native Apps to **securely communicate with other apps in the same consumer account**, supporting “sharing and merging of data” across apps.  
2. **Shareback (GA)** was announced on **Feb 10, 2026**, enabling a Native App to **request consumer permission** to share data back to the provider (or designated third parties) via a governed exchange channel; Snowflake explicitly calls out **telemetry/analytics sharing** and **compliance reporting** as key use cases.  
3. **Sharing Streamlit in Snowflake apps (Preview)** was announced on **Feb 16, 2026**, adding support to share Streamlit apps via **app-builder** or **app-viewer** URLs, plus an option to **restrict users to only Streamlit apps** (preventing access to other parts of Snowflake).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| *(Not specified in the release notes)* | — | Snowflake release notes | The three announcements are capability-level; docs pages likely contain object-level details (privileges, manifests, grants, procedure signatures). Needs follow-up extraction from the linked docs pages. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Provider telemetry “shareback” pipeline for FinOps/health signals (GA):** implement a minimal provider-side ingestion surface (e.g., landing table + incremental merge) that accepts consumer-authorized shareback data for: app usage, query cost footprint, version adoption, feature flags, errors.
2. **Inter-app communication integration pattern (Preview):** design an “extension” architecture where a core FinOps Native App can enrich other apps in the same account (e.g., governance app + cost app share a normalized “workload inventory” dataset).
3. **Streamlit distribution UX (Preview):** ship a Streamlit-based “diagnostics / setup wizard” UI that can be shared with controlled access using app-builder/app-viewer URLs; evaluate the “Streamlit-only” restriction as a safer operator UX for admins.

## Concrete Artifacts

### Draft: Shareback data model (provider-side)

```sql
-- Conceptual only (not from docs). Provider-side normalized events table.
create table if not exists APP_SHAREBACK_EVENTS (
  consumer_account_locator string,
  app_name string,
  app_version string,
  event_ts timestamp_ntz,
  event_type string,          -- e.g. QUERY_COST, FEATURE_USAGE, ERROR
  payload variant,
  received_ts timestamp_ntz default current_timestamp()
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-App Communication is **Preview**; APIs/permissions may change. | Architecture might need refactor; feature flags required. | Read Inter-app Communication doc + confirm required privileges/manifest entries. |
| Shareback mechanics depend on **app specifications / listing workflow**. | Could affect how we structure manifests + provider operations. | Read “Request data sharing with app specifications” doc and map to provider pipeline. |
| Streamlit sharing is **Preview**; access restrictions may be account/role dependent. | UX assumptions could break in some accounts. | Validate on a test account + document required grants / limitations. |

## Links & Citations

1. Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Inter-app Communication docs: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. Feb 16, 2026 — Sharing Streamlit apps (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-16-sis
6. Sharing Streamlit in Snowflake apps docs: https://docs.snowflake.com/en/developer-guide/streamlit/features/sharing-streamlit-apps

## Next Steps / Follow-ups

- Pull the linked docs pages and extract concrete implementation details (manifest entries, required privileges, API/procedure interfaces).
- Decide whether to treat Inter-App Communication as an optional plugin surface (Preview) in Mission Control architecture.
- Draft a provider-side “Shareback telemetry contract” (schema + governance + retention) suitable for FinOps insights.
