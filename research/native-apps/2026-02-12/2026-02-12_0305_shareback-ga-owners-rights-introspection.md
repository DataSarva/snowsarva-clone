# Research: Native Apps - 2026-02-12

**Time:** 03:05 UTC  
**Topic:** Snowflake Native App Framework (shareback + expanded owner’s-rights introspection)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “Shareback” is now GA**: providers can securely request permission from consumers to share data back to the provider (or designated third parties). Snowflake positions this for compliance reporting, telemetry/analytics sharing, and preprocessing via a governed exchange channel. 
2. **Owner’s-rights contexts now allow more introspection**: in owner’s-rights stored procedures, Native Apps, and Streamlit, **most SHOW/DESCRIBE commands are permitted**, and **INFORMATION_SCHEMA views + table functions are accessible**, with explicit exceptions.
3. **History functions remain restricted in INFORMATION_SCHEMA** under owner’s-rights contexts: `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER` are still blocked.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| INFORMATION_SCHEMA (views + table functions) | INFO_SCHEMA | Snowflake server release 10.3 notes | Newly accessible in owner’s-rights contexts; enables schema/object introspection from Native Apps. |
| QUERY_HISTORY / QUERY_HISTORY_BY_* / LOGIN_HISTORY_BY_USER (history functions) | INFO_SCHEMA | Snowflake server release 10.3 notes | Still restricted under owner’s-rights contexts. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Opt-in, governed “telemetry shareback” pipeline for the FinOps Native App**
   - During app setup, request shareback permission.
   - Consumers can share curated usage/health tables (or app-generated diagnostics) back to provider for cross-tenant benchmarking and proactive support.
2. **In-app installation & environment diagnostics (no support ticket required)**
   - Use SHOW/DESCRIBE + INFORMATION_SCHEMA from within owner’s-rights contexts to validate: required objects exist, privileges are correct, features are enabled.
   - Generate a diagnostic report table/JSON for support.
3. **Automated “capability discovery” at runtime**
   - Detect which optional integrations/objects are present (e.g., whether certain schemas exist) and conditionally enable UI/features.

## Concrete Artifacts

### Shareback onboarding flow (high-level)

- Step 1: Present shareback rationale + data categories (telemetry, compliance reports, anonymized aggregates).
- Step 2: App requests permission (Shareback GA capability).
- Step 3: If approved, publish a provider-facing shared dataset (tables/views) with explicit schema contract + versioning.

### Owner’s-rights introspection: diagnostic checks (pseudocode)

```sql
-- Pseudocode: run inside owner’s-rights proc / app context
-- Goal: verify required objects & privileges using SHOW/DESCRIBE and INFORMATION_SCHEMA.

SHOW SCHEMAS IN DATABASE <consumer_db>;
DESCRIBE TABLE <consumer_db>.<schema>.<table>;

SELECT *
FROM <consumer_db>.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = '<schema>'
  AND TABLE_NAME IN ('REQUIRED_TABLE_1', 'REQUIRED_TABLE_2');
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Shareback permission UX and governance requirements may be non-trivial for regulated customers | Low adoption of telemetry sharing; reduced support/benchmarking value | Prototype the permission + data contract flow; validate with 1–2 design partners. |
| INFORMATION_SCHEMA access may be database-scoped (and still limited vs ACCOUNT_USAGE) inside owner’s-rights contexts | Diagnostics might miss account-level configuration/cost signals | Validate in a test account: what INFO_SCHEMA objects are accessible from the app, and what remains blocked. |
| Restricted history functions limit workload analytics from within owner’s-rights contexts | Some “query-level FinOps” features may require alternative data sources or explicit customer-side setup | Confirm allowed alternatives (e.g., precomputed tables, event tables, or customer-managed pipelines) for needed telemetry. |

## Links & Citations

1. Feb 10, 2026: **Snowflake Native Apps: Shareback (GA)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. 10.3 Release Notes (Feb 02–05, 2026): **Owner’s rights contexts allow INFORMATION_SCHEMA, SHOW, DESCRIBE** — https://docs.snowflake.com/en/release-notes/2026/10_3
3. Release notes hub (for context / related updates) — https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Read the “Request data sharing with app specifications” doc referenced by the Shareback note and extract the concrete mechanics (roles, objects, permissions, limitations).
- Validate (hands-on) which SHOW/DESCRIBE commands and INFORMATION_SCHEMA views/table functions work inside a Native App owner’s-rights context, and capture edge cases.
- Draft a minimal telemetry schema contract (tables + versioning + anonymization rules) suitable for cross-tenant aggregation.
