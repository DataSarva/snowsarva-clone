# Research: FinOps - 2026-03-04

**Time:** 06:04 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. As of **March 1, 2026**, Snowflake **no longer charges “hybrid table requests” as a separate billing category** (previously serverless credits for reads/writes on underlying row storage). Hybrid tables are now billed via **(a) hybrid table storage (flat monthly $/GB) and (b) virtual warehouse compute** for queries. 
2. As of **Feb 24, 2026**, Snowflake budgets can be configured to **automatically call stored procedures**:
   - on **threshold events** (up to 10 actions per budget) based on **projected or actual** credit consumption, with a specified threshold percentage; and
   - on **cycle start** (budget monthly reset) to run “undo/re-enable” style actions.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budget | Snowflake object | Snowflake Budgets feature | This update adds triggers (threshold + cycle start) that invoke stored procedures. Specific system views to audit invocations/threshold events not confirmed from sources yet. |
| Stored procedure | Snowflake object | Snowflake SQL / SPs | Budget actions call a stored procedure; implies we can implement custom “policy-as-code” responses. |
| Hybrid table | Snowflake table type | Snowflake Hybrid Tables | Cost model changed: request-level serverless credit line item removed; storage + warehouse compute remain. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Budget-action automation pack (Native App):** ship a provider-managed stored procedure library (e.g., `FINOPS.BUDGET_ACTIONS.*`) that customers can wire to budgets for: suspend/resume warehouses, set/clear resource monitors, kill runaway queries, notify (email/webhook), and write an audit row to an app-owned table.
2. **“Close the loop” monthly reset:** ship a companion cycle-start procedure that reverses mitigations from the prior month (re-enable warehouses, restore max cluster, etc.) so budget governance doesn’t require manual cleanup.
3. **Hybrid table cost estimator update:** adjust cost intelligence rules to remove “hybrid table requests” as a separate cost driver after 2026-03-01; instead attribute hybrid table spend to storage + warehouse compute, and flag customers’ legacy dashboards/rules that may now double-count.

## Concrete Artifacts

### Budget actions: procedure contract (draft)

```sql
-- Conceptual interface for a FinOps Native App “action pack”.
-- Customers point budget actions at these procedures.

-- Called on threshold breach
CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_ACTIONS.ON_THRESHOLD(
  BUDGET_NAME STRING,
  THRESHOLD_PCT NUMBER,
  BASIS STRING,              -- 'PROJECTED' | 'ACTUAL'
  OBSERVED_CREDITS NUMBER,
  PERIOD_START TIMESTAMP_LTZ,
  PERIOD_END TIMESTAMP_LTZ
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
  -- 1) Write an audit row
  -- 2) Apply policy: e.g., suspend tagged warehouses / reduce sizes / notify
  SELECT OBJECT_CONSTRUCT('status','ok');
$$;

-- Called at budget cycle start
CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_ACTIONS.ON_CYCLE_START(
  BUDGET_NAME STRING,
  PERIOD_START TIMESTAMP_LTZ,
  PERIOD_END TIMESTAMP_LTZ
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
  -- Reverse last cycle’s mitigations + write audit row
  SELECT OBJECT_CONSTRUCT('status','ok');
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Availability/editions/regions for budget actions may vary. | Feature may not exist in a target customer account. | Confirm in Snowflake docs + test in a real account. |
| Required privileges for budgets calling stored procedures are not specified in the release note. | Actions may fail or require elevated roles. | Read the “Custom actions for budgets” + “Cycle-start actions for budgets” docs and capture required grants. |
| Hybrid table pricing change might impact chargeback/FinOps attribution logic. | Dashboards could show apparent cost drop or reclassification. | Compare bill line items before/after March 1, 2026 in a test account. |

## Links & Citations

1. Snowflake release note (Mar 02, 2026): Simplified pricing for hybrid tables — https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-hybrid-tables-pricing
2. Snowflake release note (Feb 24, 2026): User-defined actions for budgets — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
3. Hybrid table cost guidance: Evaluate cost for hybrid tables — https://docs.snowflake.com/en/user-guide/tables-hybrid-cost
4. Budgets docs: Custom actions for budgets — https://docs.snowflake.com/en/user-guide/budgets/custom-actions
5. Budgets docs: Cycle-start actions for budgets — https://docs.snowflake.com/en/user-guide/budgets/cycle-start-actions

## Next Steps / Follow-ups

- Pull the budgets docs to capture: exact DDL/ALTER syntax, privilege model, parameters passed to procedures (if any), and any system views for history/auditing.
- Update FinOps rule engine assumptions around hybrid tables billing categories (identify any existing “hybrid request credits” detectors and deprecate).
