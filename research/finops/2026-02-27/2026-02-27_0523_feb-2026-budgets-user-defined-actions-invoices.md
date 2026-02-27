# Research: FinOps - 2026-02-27

**Time:** 0523 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Budgets can trigger stored procedures (Feb 24, 2026):** you can configure a budget to automatically call a stored procedure when a spending threshold is reached; triggers can be based on **projected** or **actual** credit consumption; up to **10 custom actions per budget**.
2. **Budgets can trigger stored procedures at cycle start (Feb 24, 2026):** you can configure a budget to call a stored procedure when the monthly budget cycle restarts (useful for reversing prior automated actions).
3. **Invoices view/download in Snowsight (Feb 24, 2026):** On Demand accounts can view/download billing invoices directly in Snowsight.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| Budget object (Snowflake Budgets feature) | Snowflake governance object | Docs | Release note describes attaching stored-procedure actions to a budget. Exact DDL/metadata views not extracted yet. |
| Stored procedure | SQL / Java / Python procedure | Snowflake | Action target; can suspend warehouses, send alerts, log spend events, etc. |
| Invoice UI (Snowsight) | UI feature | Docs | No programmatic objects called out in the release note; likely complementary to usage views, not a new dataset. |

## MVP Features Unlocked

1. **“Budget autopilot” runbook library:** ship a set of canned stored procedures + setup wizard:
   - suspend specific warehouses at X% budget burn
   - downgrade warehouse size / auto-suspend aggressively
   - send alerts (Slack/Teams/email via external integration patterns)
   - write an audit row into a `FINOPS_BUDGET_ACTIONS_LOG` table
2. **Cycle-start remediation:** automatically re-enable or restore warehouse policies at the start of month (reverse last cycle’s emergency controls).
3. **Closed-loop FinOps automation:** connect our app’s recommendations to budget triggers so actions are enforced, not just suggested.

## Concrete Artifacts

### Suggested action log table (design sketch)

```sql
create table if not exists FINOPS_BUDGET_ACTIONS_LOG (
  ts timestamp_ntz default current_timestamp(),
  budget_name string,
  action_name string,
  trigger_kind string, -- ACTUAL | PROJECTED | CYCLE_START
  threshold_pct number(5,2),
  details variant
);
```

*(Exact integration depends on the budget custom-action stored procedure signature; needs follow-up from docs.)*

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Stored procedure invocation context/role and available inputs are unknown from release note alone. | Could block safe automation (needs least-privilege). | Read the linked “Custom actions for budgets” + “Cycle-start actions” docs; confirm signature + privileges. |
| Automation can cause disruption if misconfigured (e.g., suspending critical warehouses). | Operational risk. | Require allowlist + dry-run mode + audit logging. |
| Invoices in Snowsight may not have API exposure. | Less automation opportunity. | Check billing docs for any views/APIs. |

## Links & Citations

1. Budgets: user-defined actions release note (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Budgets custom actions docs (linked): https://docs.snowflake.com/en/user-guide/budgets/custom-actions
3. Budgets cycle-start actions docs (linked): https://docs.snowflake.com/en/user-guide/budgets/cycle-start-actions
4. Invoices in Snowsight release note (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
5. Access billing invoices docs (linked): https://docs.snowflake.com/en/user-guide/billing-invoices

## Next Steps / Follow-ups

- Pull the budgets docs and extract:
  - required privileges/roles
  - stored procedure signature + provided parameters
  - how to introspect configured actions (SHOW/DESCRIBE, views)
- Draft 2–3 reference stored procedures with safety rails (allowlists + audit logging).
