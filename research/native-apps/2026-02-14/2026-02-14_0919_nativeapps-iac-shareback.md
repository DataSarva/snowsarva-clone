# Research: Native Apps - 2026-02-14

**Time:** 09:19 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps can now (Preview) communicate with other Native Apps in the same consumer account via “Inter-app Communication”.
2. Snowflake Native Apps “Shareback” is now GA: an app can request consumer permission to share data back to the provider or a designated third party.
3. In 10.3 (Feb 02–05, 2026), Snowflake expanded what’s allowed in owner’s-rights contexts (incl. Native Apps) to permit most SHOW/DESCRIBE commands and allow access to INFORMATION_SCHEMA views/table functions, with some history functions still restricted.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| INFORMATION_SCHEMA views & table functions | INFO_SCHEMA | 10.3 release notes | Accessible from owner’s-rights contexts; history functions like QUERY_HISTORY* remain restricted. |
| (Inter-app Communication API surface) | Native Apps framework | IAC release note + linked docs | Release note points to developer guide; details TBD from full doc review. |
| App specs / listing request flow for shareback | Native Apps framework | Shareback release note + linked docs | Mechanism is “request permission … with app specifications”. |

## MVP Features Unlocked

1. **FinOps “plugin” app model (Preview path):** split capabilities into multiple Native Apps (e.g., “Cost Intelligence” + “Governance”) that can share/merge data within the same account, instead of shipping one monolith.
2. **Provider telemetry loop (GA):** implement opt-in shareback for anonymized usage/health metrics and cost outcomes to improve recommendations and reduce support back-and-forth.
3. **Self-introspection in owner’s-rights (10.3):** add a diagnostics page that runs SHOW/DESCRIBE + safe INFORMATION_SCHEMA queries for automated environment validation (warehouse existence, privileges, object inventory) without needing elevated user roles.

## Concrete Artifacts

### Diagnostics: owner’s-rights safe checks (sketch)

```sql
-- In an owner’s-rights stored proc / native app context: now generally allowed
SHOW WAREHOUSES;
SHOW DATABASES;

-- Example: safe INFORMATION_SCHEMA inventory (still validate exact permissions)
SELECT table_schema, table_name
FROM <db>.INFORMATION_SCHEMA.TABLES
WHERE table_schema NOT IN ('INFORMATION_SCHEMA');
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Inter-app Communication details (APIs, permissions, limits) are not in the short release note | Could change feasibility/architecture | Read the linked developer guide and confirm required privileges + supported patterns. |
| Shareback requires explicit consumer opt-in via app specs / listing flow | Limits what can be collected by default | Review “requesting app specs” doc and test with a sample listing. |
| INFORMATION_SCHEMA access in owner’s-rights contexts still excludes certain history functions | Diagnostics might need alternative sources | Confirm which functions/views are blocked; prefer ACCOUNT_USAGE/ORG_USAGE where appropriate. |

## Links & Citations

1. Feb 13, 2026: Native Apps Inter-App Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Inter-app Communication doc (linked from release note) — https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Feb 10, 2026: Native Apps Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Shareback doc (linked from release note) — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing
5. 10.3 release notes (owner’s-rights contexts expanded) — https://docs.snowflake.com/en/release-notes/2026/10_3

## Next Steps / Follow-ups

- Read + summarize the Inter-app Communication developer guide: required grants, object model, and any constraints.
- Prototype shareback schema + consent UX in our app UI (what we ask for, how to explain it, data minimization).
- Add an “environment diagnostics” module leveraging the expanded SHOW/DESCRIBE + INFORMATION_SCHEMA access.
