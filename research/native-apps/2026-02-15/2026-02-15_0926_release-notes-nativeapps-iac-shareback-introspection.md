# Research: Native Apps - 2026-02-15

**Time:** 09:26 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added **Inter-App Communication** for Snowflake Native Apps (Preview), allowing a native app to securely communicate with **other native apps in the same consumer account**, enabling sharing/merging data across apps.  
2. Snowflake released **Shareback** for Snowflake Native Apps as **GA**, allowing providers to request consumer permission to share data back to the provider and/or designated third parties for use cases like compliance reporting and telemetry/analytics exchange.  
3. In server release **10.3**, Snowflake expanded what’s allowed in **owner’s rights contexts** (owner’s rights stored procedures, **Native Apps**, Streamlit): most **SHOW**/**DESCRIBE** commands and **INFORMATION_SCHEMA views/table functions** are now permitted, with some history functions still restricted (e.g., QUERY_HISTORY*, LOGIN_HISTORY_BY_USER).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| INFORMATION_SCHEMA (views + table functions) | INFO_SCHEMA | Release 10.3 notes | Now accessible from owner’s rights contexts, but history functions remain restricted. |
| SHOW / DESCRIBE commands | Command | Release 10.3 notes | “Most” now allowed in owner’s rights contexts; some session/user-domain reads still blocked. |
| Shareback (app specifications / request flow) | Native App capability | Feature update (Feb 10) | Mechanism for governed data egress from consumer → provider/3P once authorized. |
| Inter-App Communication | Native App capability | Feature update (Feb 13) | Secure app↔app comm within same consumer account (Preview). |

## MVP Features Unlocked

1. **Cross-app “cost signals bus” (Preview-ready):** if inter-app communication is available, design a minimal contract so a FinOps native app can ingest / merge telemetry from other installed native apps (e.g., observability, governance apps) without external egress.
2. **Owner’s-rights introspection upgrade:** expand our installer/health-check routines to use permitted SHOW/DESCRIBE + INFORMATION_SCHEMA in owner’s-rights contexts to build a richer “environment diagnostics” report without requiring elevated manual steps.
3. **Shareback-powered telemetry export:** add an optional “shareback channel” for aggregated cost/perf metrics and anomaly summaries back to the provider (or customer-owned central account) under explicit consumer permission.

## Concrete Artifacts

### Draft: “Diagnostics pack” queries enabled by 10.3 owner’s-rights changes

```sql
-- Pseudocode / sketch: exact commands depend on what SHOW/DESCRIBE are permitted
-- Goal: gather inventory + config safely from owner’s-rights context.

-- Examples (to validate):
-- SHOW WAREHOUSES;
-- SHOW DATABASES;
-- SHOW SCHEMAS IN DATABASE <db>;

-- INFORMATION_SCHEMA examples (to validate per consumer DB context):
-- SELECT * FROM <db>.INFORMATION_SCHEMA.TABLES;
-- SELECT * FROM <db>.INFORMATION_SCHEMA.COLUMNS;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-App Communication is **Preview** and may have region/edition/feature-flag constraints. | Feature may not be available to all consumers; need graceful degradation. | Confirm eligibility + required privileges from the Inter-app Communication doc. |
| “Most SHOW/DESCRIBE commands” allowed in owner’s-rights contexts still has important exceptions. | Diagnostics could fail or be incomplete for key domains. | Build a capability test suite; enumerate allowed/blocked commands empirically. |
| Shareback requires explicit consumer permission; might add friction. | Lower opt-in rates for telemetry sharing. | Design UX + value proposition; include “local-only” mode by default. |

## Links & Citations

1. Feb 13, 2026 feature update: **Native Apps: Inter-App Communication (Preview)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Feb 10, 2026 feature update: **Native Apps: Shareback (GA)** — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. Server release 10.3: **Owner’s rights contexts allow INFORMATION_SCHEMA, SHOW, DESCRIBE** — https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Read the Inter-app Communication doc and extract: required grants, supported payload patterns, and any quotas/limits.
- Add an “introspection capabilities probe” (tiny SQL script) to detect which SHOW/DESCRIBE and INFO_SCHEMA objects are allowed in owner’s-rights contexts.
- Map Shareback to our FinOps roadmap: which metrics are valuable enough to justify the consumer permission step.
