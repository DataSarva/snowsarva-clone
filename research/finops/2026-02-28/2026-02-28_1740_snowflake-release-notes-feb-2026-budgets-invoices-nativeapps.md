# Research: FinOps - 2026-02-28

**Time:** 1740 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowsight now supports viewing and downloading billing invoices for **On Demand** accounts. 
2. Snowflake **budgets** can now be configured to automatically **call stored procedures** (a) when a spending threshold is reached and (b) when the monthly budget cycle restarts; up to **10 custom actions** can be configured per budget.
3. Two new credit/usage transparency views are now **GA** in `SNOWFLAKE.ACCOUNT_USAGE`: `CORTEX_AGENT_USAGE_HISTORY` and `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY`, each exposing credits consumed per interaction plus request/user/agent metadata.
4. Snowflake Native Apps added: **Application configuration** (Preview) for requesting consumer-provided config values (including **sensitive** values), **Inter-App Communication** (Preview), and **Shareback** (GA) for provider-directed data sharing back from consumers.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Snowsight → Billing → Invoices | UI feature | Release note (Feb 24, 2026) | For On Demand accounts; supports view + download of invoices. |
| Budgets → Custom actions / Cycle-start actions | Platform feature | Release note (Feb 24, 2026) | Actions are implemented as stored procedure calls; triggers can use projected or actual consumption. |
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | Release note (Feb 25, 2026) | Contains credits + token details per agent call; includes request/user/agent identifiers. |
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | Release note (Feb 25, 2026) | Similar structure for Snowflake Intelligence interactions; includes Intelligence ID + agent ID. |
| Native Apps: Application configuration | Native Apps feature (Preview) | Release note (Feb 20, 2026) | Allows apps to request consumer-provided config values; can mark as sensitive to avoid exposure in query history/command output. |
| Native Apps: Inter-App Communication | Native Apps feature (Preview) | Release note (Feb 13, 2026) | Secure communication among apps within the same account. |
| Native Apps: Shareback | Native Apps feature (GA) | Release note (Feb 10, 2026) | Lets apps request permission to share data back to provider/third parties.

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Budget “autopilot” playbooks**: ship stored-procedure templates + UI helpers that customers can attach to budgets (e.g., suspend warehouse(s) by tag when >90% monthly spend; re-enable at cycle start). Tie into FinOps guardrails.
2. **AI cost telemetry pack**: ingest/report `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` and `...SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` to attribute AI spend by user/team/app, and flag anomalies (spikes, high token/credit outliers).
3. **Invoice workflow integration**: add guidance + automations for On Demand accounts to periodically download invoices (manual for now) and reconcile with internal chargeback/showback dashboards; include a “Snowsight invoices available” checklist item.

## Concrete Artifacts

### Stored-procedure action skeleton for budget threshold

```sql
-- PSEUDOCODE / SKELETON (exact budget procedure signature/role requirements may vary)
-- Goal: suspend warehouses with a specific tag or naming convention.

CREATE OR REPLACE PROCEDURE finops_admin.budget_threshold_action(threshold_pct NUMBER)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
  -- Example: suspend all warehouses with name prefix FINOPS_
  -- (Replace with tag-based selection when standard in your environment.)
  LET rs RESULTSET := (SHOW WAREHOUSES LIKE 'FINOPS_%');
  -- Iterate and suspend
  -- ...
  RETURN 'OK';
$$;
```

### Query: AI credits by user (Cortex Agents)

```sql
-- Draft; validate exact column names in your account.
SELECT
  user_name,
  date_trunc('day', start_time) AS day,
  SUM(credits_used) AS credits
FROM snowflake.account_usage.cortex_agent_usage_history
WHERE start_time >= dateadd('day', -30, current_timestamp())
GROUP BY 1,2
ORDER BY 2 DESC, 3 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Budget action stored procedure privileges/roles + expected signature details are not captured in the release note. | Automations may fail or require admin setup. | Review budget docs for custom actions + test in a sandbox account. |
| Column names/types for the two new `ACCOUNT_USAGE` views are not fully enumerated in the release notes excerpt. | Queries may need adjustment. | Open the SQL reference pages and confirm schema; run `DESC VIEW`. |
| Snowsight invoice access is limited to **On Demand** accounts. | Some customers (capacity contracts) won’t benefit. | Confirm billing model and invoice access flow in docs / account UI. |
| Native Apps configuration/Inter-App Communication are **Preview**. | APIs/behavior may change; GA timeline unknown. | Track release notes + doc updates; avoid hard dependencies in production app until GA. |

## Links & Citations

1. Snowflake server release notes index (shows Feb 2026 items): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 24, 2026 — View invoices in Snowsight: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
3. Feb 24, 2026 — User-defined actions for budgets: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
4. Feb 25, 2026 — `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-cortex-agent-usage-history-view
5. Feb 25, 2026 — `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-snowflake-intelligence-usage-history-view
6. Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
7. Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
8. Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback

## Next Steps / Follow-ups

- Pull the SQL reference schemas for the two new `ACCOUNT_USAGE` views and add them to our FinOps telemetry ingestion mapping.
- Prototype a “budget action library” (stored-proc templates) + docs for common guardrails (suspend, notify, throttle).
- Decide if our Native App should adopt **app configuration** (Preview) for customer-provided keys/URLs, and how we’ll treat preview dependencies.
