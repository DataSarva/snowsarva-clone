# Research: FinOps - 2026-02-25

**Time:** 17:04 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Budgets now support **user-defined actions** that automatically invoke a **stored procedure** when a budget threshold is reached; actions can trigger on **projected or actual** credit consumption and you can configure **up to 10 actions per budget**. (GA; 2026-02-24 feature update)
2. Snowflake Budgets now support **cycle-start actions** that invoke a stored procedure when the budget cycle restarts (monthly period), enabling “reset/undo” automation at the start of each cycle. (GA; 2026-02-24 feature update)
3. Snowsight now allows **viewing and downloading billing invoices** for **On Demand** accounts (no capacity contract). (2026-02-24 feature update)
4. Snowflake Native Apps can now request consumer-provided values via **application configurations**, including support for **sensitive** configuration values that are protected from exposure in query history and command output. (Preview; 2026-02-20 feature update)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budget “custom actions” invoking stored procedures | Platform capability | Snowflake docs release note | Exact SQL surface area (e.g., CREATE/ALTER BUDGET) not validated here; likely configured in Snowsight and/or SQL. |
| Stored procedures | Snowflake object | Snowflake docs release note | Procedures are the automation hook called by budgets at threshold / cycle start. |
| Billing invoices (download) | UI capability | Snowflake docs release note | UI-based; API/SQL access not confirmed. Scoped to On Demand accounts. |
| Application configurations (Native Apps) | Native App Framework capability | Snowflake docs release note | Supports configuration keys; some can be marked “sensitive” to reduce query history / output exposure. |

## MVP Features Unlocked

1. **Budget-triggered guardrails (FinOps Autopilot):** ship a “Budget Action Pack” stored procedure template that can (a) suspend warehouses, (b) revoke warehouse monitor roles, (c) notify Slack/Teams via external function, (d) write an event row to an audit table. Then provide copy/paste instructions to wire it into budget custom actions.
2. **Cycle-start reset automation:** ship a companion cycle-start procedure that reverses prior mitigations (resume warehouses / restore grants) and writes a cycle boundary event for reporting.
3. **Native App consumer configuration wizard (Preview-aware):** in the FinOps Native App, define configuration keys for things like “notification webhook URL”, “billing owner email”, or “external account identifier”, marking secrets as **sensitive** when supported. This reduces accidental leakage of tokens in query history.

## Concrete Artifacts

### Budget-action stored procedure skeleton (concept)

```sql
-- Conceptual sketch (exact DDL + parameter contracts depend on Snowflake's Budgets action interface)
-- Goals:
-- 1) Be idempotent
-- 2) Record every invocation
-- 3) Perform safe mitigations (suspend warehouses, send alerts)

-- create or replace procedure finops.on_budget_threshold(budget_name string, threshold_pct number, mode string)
-- returns variant
-- language sql
-- as
-- $$
--   insert into finops.budget_action_events(...);
--   -- conditional mitigations
--   return object_construct('ok', true);
-- $$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact Budgets automation interface (what parameters are passed to the stored proc, what privileges are needed, whether SQL DDL exists) is not captured in the release note. | We could design the wrong proc signature / setup docs. | Read the linked Budgets docs pages + test in a sandbox account. |
| Invoice access is UI-only and only for On Demand accounts. | Limits usefulness for enterprise capacity customers; may not be automatable. | Check the “Access billing invoices” doc and any REST/UI endpoints; verify account types. |
| Native Apps “application configuration” is Preview and may change. | App UX/contract could break; feature-gating required. | Monitor release notes + implement graceful fallback path. |

## Links & Citations

1. Snowflake release notes (feature updates index; includes all referenced items): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 24, 2026 — User-defined actions for budgets: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
3. Feb 24, 2026 — View invoices in Snowsight: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
4. Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration

## Next Steps / Follow-ups

- Pull and summarize the linked Budgets docs pages (custom-actions + cycle-start-actions) with concrete setup steps + required privileges.
- Decide how Mission Control should “productize” budget actions: (a) provide stored proc templates, (b) provide a Native App setup wizard, or (c) both.
- Add feature-gating logic in the Native App to only use application configurations where supported; otherwise fall back to secure setup instructions (e.g., secrets in external integrations).