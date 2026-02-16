# Research: Native Apps - 2026-02-16

**Time:** 09:34 UTC  
**Topic:** Snowflake Native App Framework (+ nearby platform changes that unlock app capabilities)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-App Communication (Preview)**: A Snowflake Native App can now securely communicate with other Native Apps in the *same consumer account*, enabling sharing/merging data across apps. (Preview as of 2026-02-13.)
2. **Shareback (GA)**: Native Apps can request permission from consumers to share data *back to the provider* or to designated third parties, enabling governed telemetry/analytics and compliance/reporting workflows. (GA as of 2026-02-10.)
3. **Owner’s-rights contexts expanded** (applies to owner’s-rights stored procedures, **Native Apps**, Streamlit): Most **SHOW/DESCRIBE** commands are now permitted, and **INFORMATION_SCHEMA views/table functions** are now accessible, with some history-function exceptions.
4. **New org-level cost attribution**: ORGANIZATION_USAGE added premium views including **METERING_HISTORY** (hourly credits per account) and **QUERY_ATTRIBUTION_HISTORY** (attributes compute costs to queries on warehouses), rolling out through ~2026-02-09.
5. **Listing/share observability (GA)**: New INFORMATION_SCHEMA objects (LISTINGS, SHARES, AVAILABLE_LISTINGS()) and ACCOUNT_USAGE views (LISTINGS, SHARES, GRANTS_TO_SHARES) plus additional DDL coverage in ACCOUNT_USAGE.ACCESS_HISTORY for listing/share lifecycle auditing.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Inter-app Communication | Feature (Native Apps) | Release note | New app↔app comms within same account (Preview). |
| Shareback | Feature (Native Apps) | Release note | Consumer-granted permissioned data sharing back to provider / 3rd parties (GA). |
| INFORMATION_SCHEMA (views & table functions) | INFO_SCHEMA | 10.3 release note | Now accessible from owner’s-rights contexts; history fns like QUERY_HISTORY* still restricted. |
| ORGANIZATION_USAGE.METERING_HISTORY | ORG_USAGE (premium) | Release note | Hourly credit usage per account (org account). |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | ORG_USAGE (premium) | Release note | Attributes warehouse compute costs to specific queries (org account). |
| INFORMATION_SCHEMA.LISTINGS | INFO_SCHEMA | Release note | Real-time listing observability (providers). |
| INFORMATION_SCHEMA.SHARES | INFO_SCHEMA | Release note | Shares consistent w/ SHOW SHARES (providers+consumers). |
| INFORMATION_SCHEMA.AVAILABLE_LISTINGS() | INFO_SCHEMA (table fn) | Release note | Discoverable/accessible listings for consumers; supports filters. |
| ACCOUNT_USAGE.LISTINGS | ACCOUNT_USAGE | Release note | Historical listing analysis; includes dropped listings. |
| ACCOUNT_USAGE.SHARES | ACCOUNT_USAGE | Release note | Historical share analysis; includes dropped shares. |
| ACCOUNT_USAGE.GRANTS_TO_SHARES | ACCOUNT_USAGE | Release note | Historical grant/revoke operations to shares. |
| ACCOUNT_USAGE.ACCESS_HISTORY | ACCOUNT_USAGE | Release note | Now captures CREATE/ALTER/DROP on listings/shares + property changes in OBJECT_MODIFIED_BY_DDL JSON. |

## MVP Features Unlocked

1. **Native App “Cost Intelligence companion app” integration** (Preview): if Akhil’s FinOps app is modular (e.g., separate “collector” and “advisor” apps), Inter-App Communication enables one app to enrich another inside the same account without forcing the user to wire external pipelines.
2. **Provider-side telemetry ingestion (GA)**: implement opt-in shareback so customers can send anonymized usage/health metrics back to the provider account for:
   - cost benchmark comparisons,
   - proactive regression detection,
   - compliance report generation.
3. **In-app introspection UX becomes viable**: with INFORMATION_SCHEMA + SHOW/DESCRIBE now allowed in owner’s-rights contexts, we can ship more robust “self-diagnosis” flows inside the app (object discovery, grants checks, object existence, basic config validation) without asking customers to run scripts manually.

## Concrete Artifacts

### Draft: consumer opt-in telemetry via Shareback (high level)

```sql
-- Pseudocode outline (details depend on the exact app spec & shareback mechanics)
-- 1) App requests consumer permission for shareback.
-- 2) Consumer grants permission.
-- 3) App writes telemetry into a governed dataset that is shared back.
-- 4) Provider ingests + aggregates across customers.
```

### Draft: org-level cost attribution data feed

```sql
-- Organization account (premium views)
SELECT
  *
FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP());
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-App Communication is **Preview** | API/behavior may change; feature flags/availability may vary by region/account | Read the full Inter-app Communication docs + test in a dev account. |
| Shareback mechanics require specific listing/app specification patterns | Might require Marketplace listing changes or additional consent flows | Read “Request data sharing with app specifications” docs end-to-end; prototype minimal listing. |
| Owner’s-rights access still blocks some history functions | Some diagnostics (query/login history) may not be doable from owner’s-rights | Confirm exact restricted functions list; design fallbacks. |
| ORG_USAGE premium views availability + billing | FinOps features could depend on premium entitlements | Confirm entitlement requirements + pricing/availability in target customer tiers. |

## Links & Citations

1. Snowflake server release notes & feature updates index (shows the items below): https://docs.snowflake.com/en/release-notes/new-features
2. Inter-App Communication (Preview) release note (2026-02-13): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Shareback (GA) release note (2026-02-10): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. 10.3 release note (Owner’s-rights contexts expanded): https://docs.snowflake.com/en/release-notes/2026/10_3
5. New ORGANIZATION_USAGE premium views (2026-02-01): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
6. Listing/share observability (GA) (2026-02-02): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Read the Inter-app Communication docs page and extract the exact primitives/APIs/privileges so we can map it to an app-to-app modular architecture.
- Read the Shareback “requesting app specs / listing” docs and outline the minimal consent + data model required for telemetry.
- Decide whether Mission Control should prioritize an **org-account** data pipeline (ORG_USAGE.QUERY_ATTRIBUTION_HISTORY) as the canonical attribution source when available, with ACCOUNT_USAGE fallbacks.
