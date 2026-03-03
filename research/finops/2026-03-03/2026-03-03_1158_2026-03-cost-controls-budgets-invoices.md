# Research: FinOps - 2026-03-03

**Time:** 1158 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Budgets can invoke stored procedures automatically** at key points in the budget cycle (Feb 24, 2026). This includes (a) calling a stored procedure when a spending threshold is reached (projected or actual), and (b) calling a stored procedure when the monthly budget cycle restarts. You can configure up to **10 custom actions per budget**.
2. Snowflake added **CORTEX_AI_FUNCTIONS_USAGE_HISTORY** (account usage, GA as of Mar 2, 2026) to monitor Cortex AI Functions credit consumption by function, model, user, role, warehouse, and query. The accompanying guidance includes examples for alerts, budget enforcement, and query cancellation patterns.
3. **Snowsight can display and download invoices** for **On Demand** accounts (Feb 24, 2026). (Capacity-contract billing flows may differ.)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budget “custom actions” | Budget feature | Snowflake docs | Triggers stored procedures on threshold (projected/actual) and cycle start. |
| `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` | `ACCOUNT_USAGE` view | Snowflake docs | Key new telemetry foundation for AI FinOps governance. |
| Snowsight invoices | UI feature | Snowflake docs | UI-level access; may not expose new SQL objects. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Budget Action Templates” for warehouse governance**
   - Provide a library of stored procedures (or codegen) that budgets can call:
     - suspend/resume warehouse(s)
     - scale down warehouse(s)
     - set statement timeout / query tag / resource monitors (where applicable)
     - emit alerts (table log + optional webhook)
2. **FinOps Native App: budget-policy automation pack**
   - UI that helps users select threshold triggers (projected vs actual) and attach the appropriate stored proc.
   - Provide a “cycle-start reversal” proc (undo suspensions, etc.) as a first-class feature.
3. **AI FinOps module using `CORTEX_AI_FUNCTIONS_USAGE_HISTORY`**
   - Dashboards: per-model/per-user burn, top expensive queries, anomaly detection.
   - Enforcements: revoke/restore AI privileges based on monthly credit thresholds; cancel runaway AI function queries.

## Concrete Artifacts

### Artifact: Stored procedure interface (draft)

```sql
-- Draft shape only (exact signature TBD based on Snowflake budget-action integration)
-- Goal: standardize so our app can generate/configure these consistently.

-- Example: log + suspend warehouses when threshold exceeded
-- CALL FINOPS.SP_BUDGET_THRESHOLD_ACTION(
--   budget_name => 'FINOPS_PROD',
--   threshold_pct => 90,
--   trigger_basis => 'ACTUAL',
--   action => 'SUSPEND_WAREHOUSES',
--   target => 'WH_PROD,WH_ETL'
-- );
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Budget-triggered stored procedures run with predictable/secure execution context | Misconfigured privileges could lead to overbroad control (e.g., suspending wrong warehouses) | Read “Custom actions for budgets” docs; prototype in a sandbox with least-privilege roles. |
| `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` availability/latency aligns with enforcement use-cases | If delayed, automated enforcement might be too slow | Measure view freshness in a test account; if delayed, combine with QUERY_HISTORY patterns. |
| Invoice viewing in Snowsight is sufficient for audit needs | Might not cover capacity/contracted billing; may not be automatable | Confirm account type coverage + whether there is an API/export path for invoices. |

## Links & Citations

1. Release note — User-defined actions for budgets (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Release note — View invoices in Snowsight (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
3. Release note — Monitor and control Cortex AI Functions spending (GA, Mar 2, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-ai-functions-cost-management
4. View reference — `CORTEX_AI_FUNCTIONS_USAGE_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/cortex_ai_functions_usage_history
5. Guide — Managing AI Functions cost with Account Usage: https://docs.snowflake.com/en/user-guide/snowflake-cortex/ai-func-cost-management

## Next Steps / Follow-ups

- Extract exact budget-action stored procedure signature requirements + invocation context, then implement a hardened template SP.
- Add an “AI spend guardrails” page in the FinOps app backed by `CORTEX_AI_FUNCTIONS_USAGE_HISTORY`.
- Decide if invoices belong in the product (for On Demand users) or just as a doc pointer.
