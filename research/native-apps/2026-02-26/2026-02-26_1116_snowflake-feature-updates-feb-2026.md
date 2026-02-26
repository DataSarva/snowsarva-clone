# Research: Native Apps - 2026-02-26

**Time:** 11:15 UTC  
**Topic:** Snowflake Native App Framework (plus adjacent FinOps/Snowsight updates relevant to our app)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s release-notes feed shows multiple **Native Apps** feature updates in Feb 2026:
   - **Shareback** reached **General Availability** (dated **Feb 10, 2026**).
   - **Inter-App Communication** is **Preview** (dated **Feb 13, 2026**).
   - **Configuration** is **Preview** (dated **Feb 20, 2026**).
2. Snowflake’s release-notes feed shows several adjacent **FinOps/cost management** and **Snowsight** updates in Feb 2026 that can materially improve an admin/FinOps app UX:
   - **User-defined actions for budgets** (dated **Feb 24, 2026**).
   - **View invoices in Snowsight** (dated **Feb 24, 2026**).
   - **Grouped Query History in Snowsight** is **GA** (dated **Feb 23, 2026**).
   - **Performance Explorer enhancements** are **Preview** (dated **Feb 09, 2026**).
3. The above items appear under “Recent feature updates” on the Snowflake server release notes page, meaning these are **platform-level capabilities** (not just marketing/blog announcements).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (TBD) budget metadata / budget events | Unknown | Not specified in release note | Need to find the exact system tables/views/APIs for budgets + user-defined actions; likely tied to cost management features and/or Snowsight objects. |
| (TBD) invoice metadata | Unknown | Not specified in release note | “View invoices in Snowsight” implies invoice data is available in UI; confirm whether there is an API/view we can rely on or if it’s UI-only. |
| QUERY_HISTORY* (Snowsight presentation change) | ACCOUNT_USAGE / UI | Not specified in release note | Grouped Query History sounds primarily UI/UX; validate whether grouping is backed by new fields in existing views. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Native App “Shareback” GA → ship write-back workflows**
   - MVP: a “Remediation” flow that writes optimization actions/results back to a customer-controlled schema (e.g., tagging recommendations, warehouse sizing actions, budget actions) with clear auditability.
   - Why it matters: Shareback being GA reduces risk that we’re betting on unstable preview semantics.
2. **Native App “Inter-App Communication” (Preview) → modular app architecture**
   - MVP: split the FinOps surface into a “core telemetry + recommendations” app and optional companion apps (e.g., “alerts”, “governance pack”), with controlled interactions.
   - This can unlock marketplace-friendly packaging where customers install only what they need.
3. **Native App “Configuration” (Preview) → guided onboarding + policy-as-config**
   - MVP: a declarative onboarding wizard (accounts/warehouses scope, cost guardrails, alert thresholds) that persists as app configuration instead of bespoke tables.
   - Improves repeatability and reduces support burden.

(Adjacent FinOps UX)
4. **Budgets user-defined actions → automations/alerts integration**
   - MVP: integrate our recommendations with budget thresholds (e.g., when 80% burn hit, trigger action: notify, open ticket, or run a stored procedure).

## Concrete Artifacts

### Candidate roadmap slice (1–2 PRs)

- PR1: Add “Shareback-ready” schema + audit log tables + UI affordance (“Write back recommendation outcome”).
- PR2: Add “Configuration” abstraction layer in app code (even if underlying Snowflake configuration feature is preview):
  - store config as typed object
  - version it
  - render onboarding UI based on it

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Release notes list features, but not the exact developer docs / SQL surface / permissions model. | We could mis-estimate implementation effort or security review requirements. | Pull the specific Native Apps docs pages for Shareback / Inter-App Communication / Configuration; confirm required privileges + supported editions. |
| “View invoices in Snowsight” might be UI-only. | Could block “invoice” features in the native app if no programmatic surface exists. | Check for invoice-related views/APIs; confirm with Snowflake docs and/or Support. |
| Budgets “user-defined actions” might require admin setup external to the native app. | Could limit turnkey experience. | Validate whether actions can be created/managed via SQL/API and whether native apps can register handlers. |

## Links & Citations

1. Snowflake server release notes and feature updates (contains the Feb 2026 “Recent feature updates” list, including Native Apps + budgets/invoices items):
   - https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Pull the exact documentation pages for:
  - Native Apps: Shareback (GA)
  - Native Apps: Inter-App Communication (Preview)
  - Native Apps: Configuration (Preview)
- Identify the concrete system surfaces for budgets/actions and invoices (views/APIs/privileges), and whether they can be accessed by a native app.
