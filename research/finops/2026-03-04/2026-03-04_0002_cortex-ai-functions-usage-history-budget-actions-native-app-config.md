# Research: FinOps - 2026-03-04

**Time:** 00:02 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced a GA `ACCOUNT_USAGE` view **`CORTEX_AI_FUNCTIONS_USAGE_HISTORY`** that provides telemetry for **Cortex AI Functions** usage, including **credit consumption by function, model, user, role, warehouse, and query**. 
2. The release notes explicitly position this view as a foundation for **automated cost controls**, including **account-level spend alerts**, **per-user monthly limits with automated revoke/restore**, and **automated cancellation of runaway AI function queries**.
3. Snowflake budgets now support **user-defined actions** (stored procedure calls) on **threshold reached** (projected or actual) and on **cycle restart**, enabling automated FinOps remediation workflows (e.g., suspend warehouses, send alerts, log spend events).
4. Snowflake Native Apps added **Application Configuration (Preview)**, allowing apps to request consumer-provided configuration values (including “sensitive” values) without exposing them in query history/command output—useful for distributing FinOps apps that need per-consumer identifiers, URLs, tokens, etc.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` | `ACCOUNT_USAGE` view | Snowflake release notes + reference | New GA usage telemetry for Cortex AI Functions cost governance. |
| Budgets “custom actions” | Platform capability | Snowflake release notes + user guide | Can call stored procedures on threshold/cycle restart; up to 10 actions per budget. |
| Native App “application configurations” | Native Apps capability (Preview) | Snowflake release notes + dev guide | Request config keys from consumer; can be marked sensitive. |

## MVP Features Unlocked

1. **AI Functions Cost Guardrails (job + alerts):** Ship a scheduled task + stored procedure that aggregates `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` by account/user/role and triggers alerts (Slack/Teams/email via existing notification integration) when thresholds are exceeded.
2. **Automated access enforcement for AI Functions:** Implement “budget enforcement” logic that revokes/restores a role’s privilege to use AI Functions based on month-to-date credits (mirroring release note guidance).
3. **Runaway AI Function query killer:** Implement a monitor that detects high-credit/long-running AI Functions queries and cancels them automatically (replace older “query credit limit” patterns for this workload).
4. **FinOps Native App config surface:** In the FinOps Native App, define configuration keys for customer-specific knobs (e.g., budget thresholds, alert endpoints, account identifiers) using Native App configuration (Preview) to avoid secrets leaking.

## Concrete Artifacts

### Draft: data model we likely want in-app

```sql
-- Not a Snowflake-provided artifact; proposed internal aggregation table
-- Purpose: fast UI + anomaly detection without rescanning full ACCOUNT_USAGE windows.

create table if not exists FINOPS.AI_FUNCTIONS_DAILY_USAGE (
  usage_date date,
  model_name string,
  function_name string,
  user_name string,
  role_name string,
  warehouse_name string,
  credits number(38,9),
  queries number,
  updated_at timestamp_ntz
);
```

### Draft: remediation hooks via budget custom actions

```sql
-- Pattern: budget custom action calls a stored procedure
-- SP can suspend warehouses / disable roles / send notification.
-- Actual parameters & invocation are defined by Snowflake budget custom actions UX/API.

create or replace procedure FINOPS.ACTION_ON_BUDGET_THRESHOLD()
returns string
language sql
as
$$
  -- Example: write an event record; call a notification integration; etc.
  insert into FINOPS.BUDGET_EVENTS values (current_timestamp(), 'THRESHOLD_REACHED');
  return 'ok';
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` fields/latency/retention are not captured in the short release note excerpt. | Could affect near-real-time controls and historical reporting accuracy. | Read the view reference and capture schema + retention/latency guarantees. |
| Budget custom actions execution semantics (identity/role used, retries, failure behavior) are unknown from excerpt. | Risk of unsafe automated remediation or missed actions. | Read budget custom action docs; test in a sandbox account. |
| Native App “Configuration” is Preview; availability/limitations may change. | Might require fallbacks for GA release. | Track Native Apps config doc updates and test across accounts. |

## Links & Citations

1. Release notes: Monitor and control Cortex AI Functions spending (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-ai-functions-cost-management
2. View reference: `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` — https://docs.snowflake.com/en/sql-reference/account-usage/cortex_ai_functions_usage_history
3. User guide: Managing AI Functions Cost with Account Usage — https://docs.snowflake.com/en/user-guide/snowflake-cortex/ai-func-cost-management
4. Release notes: User-defined actions for budgets — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
5. Release notes: Snowflake Native Apps: Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
6. Dev guide: Application configuration — https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration

## Next Steps / Follow-ups

- Pull the full schema + sample queries from the AI Functions cost management user guide and turn them into a reusable “AI spend controls” module.
- Verify how budget custom actions authenticate/execute, and document safe patterns (idempotency, rate limits, rollback/cycle-start reversal).
- Prototype Native App config keys needed for our FinOps app (alert webhook URL, budget thresholds, enforcement mode) + mark sensitive where needed.
