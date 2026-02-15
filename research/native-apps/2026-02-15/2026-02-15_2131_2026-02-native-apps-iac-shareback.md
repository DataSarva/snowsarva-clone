# Research: Native Apps - 2026-02-15

**Time:** 21:31 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (IAC) is available in Preview (Feb 13, 2026)** and lets one Snowflake Native App securely communicate with other apps installed in the *same consumer account* by exposing callable interfaces (functions/procedures) governed by app roles.
2. IAC supports a **handshake workflow** where a client app (a) identifies the server app’s installed name via a **CONFIGURATION DEFINITION** request, (b) requests/receives approval for a **CONNECTION application specification**, then (c) calls the server app’s interfaces.
3. **Shareback is GA (Feb 10, 2026)**: a Snowflake Native App can request permission from consumers to **share data back** to the provider or designated third parties through **shares + listings**, enabling governed telemetry/analytics, compliance reporting, preprocessing, and support diagnostics.
4. For shareback via listings, apps typically rely on **automated granting of privileges** and require **`manifest_version: 2`**; LISTING app specifications are **1:1 with a listing** (can’t create multiple specs for the same listing).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `CONFIGURATION DEFINITION` | Native App object | Native Apps dev guide | Used by IAC client apps to request the server app name (because consumers can rename apps at install). |
| `APPLICATION SPECIFICATION` (`CONNECTION`) | Native App object | Native Apps dev guide | Used by IAC to request and approve an app-to-app connection handshake. |
| `APPLICATION SPECIFICATION` (`LISTING`) | Native App object | Native Apps dev guide | Used by shareback to request approval for target accounts + listing configuration. |
| `SHARE` | SQL object | Docs: secure data sharing | App creates a share containing database objects to share back. |
| `LISTING` (external listing attached to a share) | SQL object | Docs: CREATE LISTING | Mechanism to share data across accounts/regions; LISTING app specs reference a listing. |
| `ALTER APPLICATION ... SET CONFIGURATION DEFINITION ...` | SQL statement | IAC docs excerpt | Example mechanism for client setup to request server app name. |
| `ALTER APPLICATION ... SET APP SPEC ...` | SQL statement | App specs docs excerpt | Used to request/define app specifications (CONNECTION/LISTING, etc.). |

## MVP Features Unlocked

1. **FinOps “companion app” architecture (Preview → plan now):** Split the product into a core FinOps app + optional “integration apps” (e.g., ingest/connector app, governance app). Use IAC so the core app can call integration app procedures to pull/enrich metadata without requiring the provider to ship a monolith.
2. **Telemetry shareback (GA now):** Add an *opt-in* flow that requests LISTING shareback approval, then publishes governed anonymized usage + outcomes (e.g., savings realized, query patterns, config health) back to the provider account for product analytics and benchmarking.
3. **Regulated audit export (GA now):** Provide a pre-built shareback pathway for compliance artifacts (e.g., cost allocation / budget enforcement logs) to a consumer-designated third-party account.

## Concrete Artifacts

### Design sketch: Shareback telemetry datasets

- Objects to share back (example):
  - `APP_DB.TELEMETRY.EVENTS_DAILY`
  - `APP_DB.TELEMETRY.FEATURE_USAGE_DAILY`
  - `APP_DB.TELEMETRY.SAVINGS_ESTIMATES_DAILY`
- Publish via:
  - `CREATE SHARE <share_name>` + grants
  - `CREATE LISTING <listing_name> ...` attached to the share
  - `ALTER APPLICATION SET APP SPEC <spec_name> TYPE=LISTING ...` to request target accounts / approval

*(Implementation details depend on Native App packaging constraints and the exact app role model; treat this as a planning artifact.)*

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| IAC is **Preview** | APIs/behavior may change; avoid hard dependencies for GA commitments | Track docs + release notes; test in a dev account before committing architecture. |
| Shareback through listings may require specific consumer UX flows (approval, target accounts, auto-fulfillment) | Could add friction to onboarding | Prototype the consumer approval flow + document minimal steps; create guided UI/SQL helper. |
| Exact privileges/manifest entries required for share/listing creation | App might fail install/upgrade if not requested properly | Cross-check manifest_version 2 + required privileges in docs; run install tests. |

## Links & Citations

1. Release note: Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/release-notes/2026/other/2026-02-13-nativeapps-iac.html
2. Native Apps dev guide: Inter-app Communication: https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication
3. Release note: Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/release-notes/2026/other/2026-02-10-nativeapps-shareback.html
4. Native Apps dev guide: Request data sharing with app specifications: https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Draft an internal ADR: “FinOps Native App modularization via IAC” (even if we gate it until GA).
- Add a backlog item for a minimal shareback telemetry dataset + consumer approval guide.
- On next watch cycle, scan for any *FinOps-adjacent* release notes (resource monitors, budgets, cost management views).