# Research: FinOps - 2026-03-02

**Time:** 0549 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Budgets can now be configured to automatically call **stored procedures** when a spending threshold is reached (up to **10** custom actions per budget), triggering on **projected or actual** credit consumption. (Release note, Feb 24 2026)
2. Budgets can also call a stored procedure when the **monthly budget cycle restarts**, enabling “undo” automations (re-enable warehouses, notifications, etc.). (Release note, Feb 24 2026)
3. Snowsight can now **view + download billing invoices** for **On Demand** accounts. (Release note, Feb 24 2026)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budgets (Snowsight + SQL budget objects) | Platform feature | Snowflake Release Notes | Exact SQL surface + system views to query budget/action status not validated in this check. |
| Stored procedures used as budget actions | SQL object | Snowflake Release Notes | Procedure is the automation hook; procedure can log to tables / send notifications / suspend warehouses. |
| Billing invoices (Snowsight UI) | UI feature | Snowflake Release Notes | UI access; any programmatic invoice export API not checked. |

## MVP Features Unlocked

1. **“Budget Action Kit”** for Mission Control: ship a ready-to-install stored procedure template that (a) writes a normalized event row into a table and (b) optionally suspends/resumes warehouses based on budget thresholds.
2. **Budget action observability dashboard**: ingest those event rows into the app’s own tables and surface “what was auto-paused, when, why, and by which budget,” with an acknowledgement workflow.
3. **Invoice-awareness** (On Demand): add a lightweight admin checklist + deep link into Snowsight invoices to close the loop between credit usage anomalies and invoices.

## Concrete Artifacts

### Stored procedure skeleton for budget actions (starter)

```sql
-- Pseudocode / skeleton: adapt role/permissions + notification integration as needed.
-- Goal: a single procedure that can be wired to multiple budgets.

CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_ACTION_HANDLER(
  ACTION_TYPE STRING,         -- e.g. 'THRESHOLD' | 'CYCLE_START'
  BUDGET_NAME STRING,
  THRESHOLD_PCT NUMBER,
  PROJECTED_OR_ACTUAL STRING, -- 'PROJECTED' | 'ACTUAL'
  CONTEXT VARIANT
)
RETURNS STRING
LANGUAGE SQL
AS
$$
  -- 1) Write an immutable event row
  INSERT INTO FINOPS.BUDGET_ACTION_EVENTS(ts, action_type, budget_name, threshold_pct, mode, context)
  SELECT CURRENT_TIMESTAMP(), :ACTION_TYPE, :BUDGET_NAME, :THRESHOLD_PCT, :PROJECTED_OR_ACTUAL, :CONTEXT;

  -- 2) Optional: automated response (example: suspend a warehouse)
  -- EXECUTE IMMEDIATE 'ALTER WAREHOUSE ... SUSPEND';

  RETURN 'ok';
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Budget action procedure call semantics + parameter payload are not captured in the release note | Implementation may need adjustments to match Snowflake’s exact invocation contract | Read “Custom actions for budgets” + “Cycle-start actions for budgets” docs and test in a sandbox account |
| Invoices feature may be UI-only (Snowsight) | Limited automation; may be a link-only feature in the app | Confirm if invoices are exposed via any API/export beyond UI |

## Links & Citations

1. Feb 24, 2026: User-defined actions for budgets — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Custom actions for budgets — https://docs.snowflake.com/en/user-guide/budgets/custom-actions
3. Cycle-start actions for budgets — https://docs.snowflake.com/en/user-guide/budgets/cycle-start-actions
4. Feb 24, 2026: View invoices in Snowsight — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
5. Access billing invoices — https://docs.snowflake.com/en/user-guide/billing-invoices

## Next Steps / Follow-ups

- Pull the exact docs for budget action procedure invocation contract (inputs/identity/role) and codify it into our app’s install guide + sample procedure.
- Decide whether Mission Control should ship a “default response policy” (pause warehouses, notify Slack/email, open ticket) as configurable modules.
