# Research: FinOps - 2026-02-25

**Time:** 23:12 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake budgets can now be configured to **automatically call stored procedures** when (a) a budget threshold is reached and (b) when the budget cycle restarts; up to **10 custom actions per budget**. Threshold triggers can be based on **projected or actual** credit consumption. 
2. Snowsight can now **view and download billing invoices** for **On Demand** accounts (accounts without a capacity contract).
3. Snowflake Native Apps now support **application configurations (Preview)**: apps define configuration keys and request consumer-provided values; configuration values can be marked **sensitive** to reduce exposure in query history/command output.
4. Snowflake Native Apps now support **Inter-App Communication (Preview)** to securely communicate with other apps in the same account.
5. Snowflake Native Apps **Shareback is GA**: an app can request permission to share data back to the provider (or designated third parties), supporting telemetry/analytics sharing and compliance reporting.
6. Streamlit in Snowflake apps can be shared via **app-builder/app-viewer URLs (Preview)** and can restrict users to only Streamlit apps (preventing access to other Snowflake areas).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budgets | Object | Snowflake Budgets feature | New ability: call stored procedures on threshold + cycle start. Need to confirm exact SQL surfaces (e.g., CREATE/ALTER BUDGET syntax + how actions are stored/inspected). |
| Stored Procedures | Code object | Customer-defined | Used as the “action handler” to suspend warehouses, send alerts, log spend events, etc. |
| Invoices (Snowsight UI) | UI/Account feature | Billing | No programmatic view mentioned in release note; validate if any ACCOUNT_USAGE/ORG_USAGE exposure exists. |
| Native App application configuration keys/values | Native App Framework | Native Apps | Sensitive configs intended to reduce exposure in query history/command output; validate exact guarantees + access rules. |
| Inter-app communication endpoints | Native App Framework | Native Apps | Preview; validate required privileges + patterns (server app vs client app). |
| Shareback shares / app specs | Native App Framework | Native Apps | GA; validate exact objects involved (listing/app specs, share objects, consumer permission flow). |

## MVP Features Unlocked

1. **Budget “autopilot” enforcement mode** (FinOps app): ship a managed stored procedure that budgets can call to automatically (a) suspend or resize warehouses, (b) set resource monitors, or (c) flip warehouse auto-suspend settings when spend threshold is hit. Provide a safe “dry-run” mode that only logs proposed actions.
2. **Month-start reset workflows**: use cycle-start actions to re-enable resources that were suspended last month and to emit a “new cycle” audit record (table log + notification), making budget enforcement reversible and predictable.
3. **Native-App-driven configuration onboarding**: move “setup inputs” (e.g., Slack webhook, email, external cost center id, target warehouse names) into **Native App Configuration (Preview)** so consumer admins can provide them securely without copy/pasting into worksheets.
4. **Provider telemetry via Shareback (GA)**: implement a shareback pipeline that sends anonymized usage/health/cost KPIs back to the provider account for benchmarking and proactive support.
5. **Composable app ecosystem**: leverage Inter-App Communication (Preview) to integrate a FinOps app with governance/observability apps (e.g., share policy findings + cost anomalies across apps).

## Concrete Artifacts

### Budget threshold action pattern (pseudocode)

```sql
-- Conceptual flow (exact syntax to validate):
-- 1) Customer creates budget and registers an action stored procedure.
-- 2) When threshold hit, Snowflake calls the procedure.
-- 3) Procedure enforces policy + logs an auditable event.

-- Stored proc responsibilities:
-- - Determine whether trigger was based on projected vs actual consumption
-- - Identify impacted resources (warehouses, jobs) via app configuration
-- - Apply safe policy actions (suspend/resize/notify/log)
-- - Insert an event row into <FINOPS_DB>.<SCHEMA>.BUDGET_ENFORCEMENT_EVENTS
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact SQL DDL/DCL surface for “budget custom actions” (how to define, list, and audit) is not captured in the release note excerpt. | Could slow implementation or require UI-only flows. | Read the linked Budgets docs (custom-actions + cycle-start-actions) and confirm SHOW/DESCRIBE visibility + caller context. |
| “Sensitive” application configuration values: the degree of redaction/non-logging may be limited. | Risk of secrets leakage in logs/query history. | Validate the Native Apps configuration docs; test behavior in query history and command output. |
| Inter-App Communication is Preview and may change. | Integration work may churn. | Build behind a feature flag; validate GA timeline. |
| Invoice viewing is Snowsight for On Demand only; may not help capacity-contract customers. | Limited customer coverage. | Check billing-invoices docs for eligibility details and any API/SQL exposure. |

## Links & Citations

1. User-defined actions for budgets (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. View invoices in Snowsight (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
3. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Native Apps: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
5. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Sharing Streamlit apps (Preview) (Feb 16, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-16-sis

## Next Steps / Follow-ups

- Pull + summarize the linked budget docs (custom-actions, cycle-start-actions) to confirm exact SQL + auditing surfaces.
- Prototype a minimal “budget action handler” stored procedure with a logging table schema.
- Validate Native App Configuration “sensitive” behavior with a toy app: confirm what shows in query history.
