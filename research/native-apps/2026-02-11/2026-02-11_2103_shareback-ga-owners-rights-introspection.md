# Research: Native Apps - 2026-02-11

**Time:** 21:03 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “Shareback” is now GA (Feb 10, 2026).** Native Apps can request permission from consumers to share data back with the provider or designated third parties via a governed workflow.
2. Snowflake explicitly positions Shareback as enabling **compliance reporting, telemetry/analytics sharing, and data preprocessing** scenarios through a secure data exchange channel.
3. In server release **10.3 (Feb 02–05, 2026)**, Snowflake expanded the **owner’s-rights context** permission model (owner’s-rights stored procedures, Native Apps, Streamlit) to allow substantially more **introspection**:
   - Most **SHOW** and **DESCRIBE** commands are now permitted (with exceptions for session/user-specific domains).
   - **INFORMATION_SCHEMA** views and table functions are accessible in owner’s-rights contexts, except some history functions remain restricted (e.g., QUERY_HISTORY*, LOGIN_HISTORY_BY_USER).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| INFORMATION_SCHEMA.* (views + table functions) | INFO_SCHEMA | 10.3 release notes | Now accessible in owner’s-rights contexts (with stated history-function exceptions). Exact accessible objects depend on the specific domain + command. |
| SHOW <object> / DESCRIBE <object> outputs | Command | 10.3 release notes | “Most” now allowed for owner’s-rights contexts; exceptions for session/user domains. |
| (Shareback workflow objects) | Unknown | Shareback release note | Release note points to “Request data sharing with app specifications”; need to confirm the exact SQL/API surface (e.g., app spec fields, listing/app spec lifecycle) and any account_usage telemetry. |

## MVP Features Unlocked

1. **In-app “Consent-based telemetry” channel (Shareback GA):**
   - Implement an opt-in flow for customers to share FinOps telemetry back to provider (or to a trusted third party) to enable benchmarking and proactive optimization recommendations.
2. **Self-diagnostics panel powered by INFORMATION_SCHEMA introspection:**
   - In an owner’s-rights Native App, add “Environment checks” (warehouse sizing, task state, object existence, grants) using INFORMATION_SCHEMA + SHOW/DESCRIBE to reduce support friction.
3. **Automated “least surprise” support bundle generator:**
   - Generate a sanitized diagnostics bundle (object lists, configuration, limited metadata) directly inside the app without requiring elevated manual steps—bounded by the new allowed SHOW/DESCRIBE/INFO_SCHEMA access.

## Concrete Artifacts

### Draft: Minimal diagnostics queries to validate new owner’s-rights introspection surface

```sql
-- Examples (validate in an owner’s-rights stored proc / native app context):

-- Warehouse + database inventory (INFO_SCHEMA):
SELECT *
FROM INFORMATION_SCHEMA.WAREHOUSES;

SELECT *
FROM INFORMATION_SCHEMA.DATABASES;

-- Object existence / metadata (INFO_SCHEMA):
SELECT *
FROM INFORMATION_SCHEMA.SCHEMATA
WHERE CATALOG_NAME = CURRENT_DATABASE();

-- SHOW/DESCRIBE samples (expect most to work; confirm exceptions):
SHOW WAREHOUSES;
SHOW DATABASES;
DESCRIBE WAREHOUSE <name>;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Shareback GA details may require specific listing/app-spec configuration (and may have edition/region constraints). | Could block implementation or require Marketplace/listing changes. | Read the “Request data sharing with app specifications” doc + test in a dev listing. |
| “Most SHOW/DESCRIBE” allowance still has important exceptions; behavior may vary by command/object type. | Diagnostics feature could fail silently or need fallback paths. | Create a command matrix and run it inside owner’s-rights contexts (Native App + owner’s-rights stored proc). |
| INFO_SCHEMA access may not include the exact history/usage datasets FinOps wants (e.g., query history). | Limits value of in-app optimization insights without ACCOUNT_USAGE permissions. | Verify which history functions are blocked and which ACCOUNT_USAGE views are available/appropriate for the app’s security posture. |

## Links & Citations

1. Feb 10, 2026: Native Apps Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. 10.3 Release Notes (Feb 02–05, 2026) — owner’s-rights contexts changes: https://docs.snowflake.com/en/release-notes/2026/10_3
3. Reference linked from Shareback note (“Request data sharing with app specifications”): https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Pull and summarize the Shareback “app specifications” doc into a concrete implementation checklist (provider + consumer steps).
- Build a quick test harness in a Native App to validate the owner’s-rights SHOW/DESCRIBE/INFO_SCHEMA surface and document the allowed command matrix.
- Decide the product stance for telemetry: default off; explicit consent; define what data is collected and how it’s stored/processed.
