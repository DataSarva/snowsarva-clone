# Research: Native Apps - 2026-02-26

**Time:** 23:19 UTC  
**Topic:** Snowflake Native App Framework (plus FinOps-adjacent platform updates)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps “Shareback” is GA**: providers can request permission from consumers to share data back to the provider (or designated third parties) via governed, secure exchange. This is positioned for compliance reporting, telemetry/analytics, and preprocessing workflows.  
   Source: Snowflake release note (Feb 10, 2026) on Shareback GA.
2. **Native Apps “Inter‑App Communication” is in Preview**: apps in the same account can securely communicate with other apps, enabling sharing/merging data across apps within a consumer account.  
   Source: Snowflake release note (Feb 13, 2026) on Inter‑App Communication.
3. **Native Apps “Application configuration” is in Preview**: apps can define configuration keys to request values from consumers; configurations can be marked **sensitive** to reduce exposure in query history/command output (intended for API keys/tokens).  
   Source: Snowflake release note (Feb 20, 2026) on Application configuration.
4. **Budgets can trigger stored procedures (user-defined actions)** at threshold events (projected vs actual credit consumption) and at **cycle start**; up to **10 custom actions per budget**.  
   Source: Snowflake release note (Feb 24, 2026) on budget user-defined actions.
5. **Invoices are viewable/downloadable in Snowsight** for **On Demand** accounts.  
   Source: Snowflake release note (Feb 24, 2026) on billing invoices in Snowsight.
6. Two new **ACCOUNT_USAGE** views are now **GA** for AI/agent cost attribution:
   - `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` (credits/tokens/metadata per agent call)
   - `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (credits/tokens/metadata per Snowflake Intelligence interaction)
   Sources: Snowflake release notes (Feb 25, 2026) for both views.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | view | ACCOUNT_USAGE | GA as of 2026-02-25. Per-agent-call credits/tokens, request/user/agent metadata. |
| `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | view | ACCOUNT_USAGE | GA as of 2026-02-25. Per-interaction credits/tokens plus request/user/Snowflake-Intelligence + agent metadata. |
| Budget stored-procedure callbacks | feature | Budgets framework | Threshold + cycle-start hooks; up to 10 custom actions/budget. |

## MVP Features Unlocked

1. **Native App “bring-your-own-endpoints” configuration flow**: use application configurations (sensitive keys) to collect consumer-specific values (webhook URL, external service URL, API token, “server app name” for IAC) without leaking into query history.
2. **Inter-App “Cost Intelligence Hub” pattern (Preview)**: one “platform” app aggregates/normalizes spend/attribution metrics from other installed apps via inter-app communication, then exposes unified dashboards + alerts.
3. **Closed-loop FinOps automation via Budgets → Stored Proc actions**: ship sample stored procedures that (a) suspend or resize warehouses, (b) tag/record an “incident”, (c) emit custom notifications, and (d) automatically re-enable at cycle start.
4. **AI feature chargeback**: wire the new ACCOUNT_USAGE views into our FinOps data model to attribute Cortex Agent / Snowflake Intelligence spend by user/request/agent id and surface “top AI cost drivers” dashboards.

## Concrete Artifacts

### Budget automation stored procedure skeleton

```sql
-- Example skeleton: suspend a warehouse when a budget action fires
-- (Exact event payload/arguments should be validated against docs.)
create or replace procedure finops_actions.suspend_wh(wh_name string)
returns string
language sql
as
$$
  alter warehouse identifier(:wh_name) suspend;
  return 'suspended ' || :wh_name;
$$;
```

### Data model idea: AI usage attribution

```sql
-- Pseudocode query shape
select
  start_time,
  user_name,
  request_id,
  agent_id,
  credits_used,
  total_tokens,
  tool_name
from snowflake.account_usage.cortex_agent_usage_history
where start_time >= dateadd('day', -7, current_timestamp());
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview features (IAC + app configuration) may change semantics/SQL surfaces | Could require refactors in app manifests + setup UX | Read the linked developer-guide pages + test in a preview-enabled account. |
| Budget stored proc callback signature / payload details not captured in release note | Automation examples might be wrong | Pull the “Custom actions for budgets” + “Cycle-start actions” docs and implement exactly. |
| “Sensitive configuration” guarantees (what is/ isn’t logged) may be nuanced | Risk of leaking secrets | Confirm behavior in docs + run a query-history redaction test. |

## Links & Citations

1. View invoices in Snowsight (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
2. User-defined actions for budgets (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
3. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Native Apps: Inter‑App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
5. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY (GA) (Feb 25, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-cortex-agent-usage-history-view
7. ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY (GA) (Feb 25, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-snowflake-intelligence-usage-history-view

## Next Steps / Follow-ups

- Pull and summarize the linked docs for:
  - App configuration (surface area, SQL/manifest objects, “sensitive” handling details)
  - Inter-app communication (permissions model, identifiers, limitations)
  - Budget custom actions (procedure signature + how to pass parameters)
- Add these items to the FinOps Native App roadmap:
  - “Budget action pack” (stored proc templates + UI wizard)
  - “AI cost attribution” dashboards + alerts
