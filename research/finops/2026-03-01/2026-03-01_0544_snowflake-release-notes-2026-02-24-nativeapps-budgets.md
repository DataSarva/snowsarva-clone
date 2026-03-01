# Research: FinOps - 2026-03-01

**Time:** 0544 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

Source sweep focused on Snowflake release notes items that unlock immediate FinOps + Native Apps product surface.

---

## Accurate Takeaways

1. **Budgets can now invoke stored procedures automatically** when (a) a spending threshold is reached (projected or actual consumption) and (b) when the monthly budget cycle restarts. Up to **10 custom actions per budget** can be configured. (Feb 24, 2026 feature update)
2. **Snowsight can now view and download billing invoices** for **On Demand** accounts (no capacity contract). (Feb 24, 2026 feature update)
3. **Native Apps: “Application configuration” (Preview)** lets an app request configuration values from consumers, including **sensitive** config values that are protected from exposure in query history / command output. (Feb 20, 2026 feature update)
4. **Native Apps: Inter-App Communication (Preview)** enables secure communication between apps in the same account, enabling data sharing/merging workflows across multiple installed apps. (Feb 13, 2026 feature update)
5. **Native Apps: Shareback is GA**: apps can request permission from consumers to share data back to the provider or designated third parties, supporting telemetry/analytics and compliance reporting patterns. (Feb 10, 2026 feature update)

## Snowflake Objects & Data Sources

| Object/View/Feature | Type | Source | Notes |
|---|---|---|---|
| Budgets → custom actions | Platform feature | Docs (release note + user guide) | Triggers stored procedures based on % threshold; projected vs actual; cycle-start action at month boundary. |
| Snowsight invoices UI | UI feature | Docs (release note + user guide) | Applies to On Demand accounts; enables download. |
| Native Apps → application configuration | Native App feature (Preview) | Docs (release note + developer guide) | Supports “sensitive” values for things like API keys/tokens; avoids query history exposure. |
| Native Apps → inter-app communication | Native App feature (Preview) | Docs (release note + developer guide) | Secure app↔app within same account; enables multi-app compositions. |
| Native Apps → shareback | Native App feature (GA) | Docs (release note + developer guide) | Consumer-approved data sharing back to provider/3rd parties. |

## MVP Features Unlocked

1. **“Budget Action Pack” for FinOps automation (Native App add-on)**
   - Ship stored procedures + setup wizard for: suspend/resume warehouses, set warehouse max cluster, lower auto-suspend, notify Slack/Email (via customer’s proc), and log events to a ledger table.
   - Include a **cycle-start reset** proc to undo “emergency brakes” from last cycle.
2. **Invoice ingestion/attachment workflow (On Demand)**
   - Provide a lightweight runbook + UI cues: “Download invoice from Snowsight → upload to app for reconciliation,” enabling billed-vs-used credit reconciliation and chargeback reporting.
3. **Consumer config UX patterns**
   - Use **application configuration** for customer-provided identifiers/URLs and sensitive tokens (Preview) rather than ad-hoc tables/secrets.

## Concrete Artifacts

### Budget action observability (suggested schema)

```sql
-- (Draft) event ledger table for budget actions; designed to be written by stored procs.
create table if not exists FINOPS.BUDGET_ACTION_EVENTS (
  event_ts timestamp_tz default current_timestamp(),
  budget_name string,
  action_name string,
  action_type string, -- THRESHOLD | CYCLE_START
  threshold_percent number(5,2),
  basis string,       -- PROJECTED | ACTUAL
  payload variant,
  status string,      -- STARTED | SUCCESS | FAILED
  error_message string
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Budget stored-proc execution semantics (auth context, retries, idempotency expectations) vary by account policies. | Automation may be brittle without guardrails. | Read budgets custom-actions + cycle-start guides; validate in a test account. |
| Invoices-in-Snowsight applies to On Demand accounts only. | Feature may not help capacity customers. | Confirm via billing invoice docs + account type. |
| Native Apps configuration + inter-app communication are Preview. | API surface could change; may not be enabled in all regions/accounts. | Track preview availability + docs changes. |

## Links & Citations

1. Snowflake server release notes / feature updates (index): https://docs.snowflake.com/en/release-notes/new-features
2. User-defined actions for budgets (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
3. View invoices in Snowsight (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
4. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
5. Native Apps: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
6. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback

## Next Steps / Follow-ups

- Validate budgets stored-proc requirements and recommended idempotency patterns; create a minimal “suspend warehouse” proc + test.
- Decide whether to treat invoices as a manual ingestion path (On Demand only) or purely informational for reconciliation UX.
- Track Preview features (app configuration, inter-app comms) for GA timeline; design abstractions so they can be optional capabilities.
