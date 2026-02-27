# Research: FinOps - 2026-02-27

**Time:** 1735 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Budgets now support **user-defined actions** that automatically **call stored procedures** when a spending threshold is reached, based on **projected or actual credit consumption**; up to **10 custom actions** per budget. 
2. Snowflake Budgets now support **cycle-start actions** that automatically **call stored procedures** when the budget cycle restarts (monthly period), enabling “undo”/reset automation at the start of the next cycle.
3. These features enable native, in-platform FinOps automation patterns (e.g., suspend warehouses, send alerts, write to audit tables) without external schedulers, with the enforcement logic encapsulated in customer-owned stored procedures.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budgets (Snowsight + SQL objects) | Feature | Release notes | Exact SQL object names not in the release note; see docs links below. |
| Stored Procedure (customer-defined) | SQL object | Release notes | Called by budget events (threshold reached / cycle start). |
| Credit consumption (actual / projected) | Metric | Release notes | Budget evaluates thresholds using actual or projected credit use. Underlying system views not specified in release note. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Budget-driven “auto-throttle” policy engine**: Ship a default stored-procedure template that suspends/sizes down a set of tagged warehouses when a budget hits (e.g.) 80% projected or 90% actual.
2. **Budget event journal**: A stored procedure that writes events (budget name, threshold, actual/projected, timestamp, action taken) into an app-owned table for audit + UI timelines.
3. **Cycle reset workflow**: Cycle-start stored procedure that re-enables previously suspended warehouses and posts a “new cycle” notification (also useful for reapplying guardrails every month).

## Concrete Artifacts

### Stored procedure skeleton (action executor)

```sql
-- Pseudocode: adapt to Snowflake Scripting / JS SP based on customer standards.
-- Called by budget custom action / cycle-start action.

-- Inputs: likely include budget name + threshold context (exact signature TBD; check docs).

-- 1) Log event
-- INSERT INTO FINOPS_DB.FINOPS_SCHEMA.BUDGET_ACTION_LOG (...) VALUES (...);

-- 2) Enforce guardrail
-- Example: suspend warehouses with a specific tag
-- FOR w IN (SELECT ... FROM <warehouse inventory view>) DO
--   EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || IDENTIFIER(w.name) || ' SUSPEND';
-- END FOR;

-- 3) Notify
-- Could call SYSTEM$SEND_EMAIL / webhook integration / notification integration if available.
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact stored procedure signature + available context fields for budget-triggered calls are unclear from release notes. | Could block providing a “drop-in” SP template. | Read the linked docs pages and extract exact parameter contracts. |
| Permissions/roles for budget-triggered stored procedure execution are not specified here. | Potential security risk or unexpected failures. | Validate execution context + required grants in docs. |

## Links & Citations

1. Release note (Feb 24, 2026) — “User-defined actions for budgets”: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Docs — “Custom actions for budgets”: https://docs.snowflake.com/en/user-guide/budgets/custom-actions
3. Docs — “Cycle-start actions for budgets”: https://docs.snowflake.com/en/user-guide/budgets/cycle-start-actions

## Next Steps / Follow-ups

- Pull the docs for the budget action stored-procedure contract (parameters, role context, error handling) and turn it into an app-ready template + guardrails.
- Decide how Mission Control should integrate: (a) generate SP templates + docs, (b) expose a UI wizard that creates budgets + binds actions, or (c) both.
