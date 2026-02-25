# Research: FinOps - 2026-02-25

**Time:** 0500 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake Budgets can now be configured to automatically call stored procedures when (a) a spend threshold is reached and (b) when the monthly budget cycle restarts; up to 10 custom actions can be defined per budget. (Feature update dated Feb 24, 2026) [1]
2. Budget custom actions can trigger based on **projected** or **actual** credit consumption, and thresholds are specified as a percentage. [1]
3. Snowsight now supports viewing/downloading billing invoices for **On Demand** accounts (no capacity contract). (Feature update dated Feb 24, 2026) [2]
4. Native Apps can request configuration values from consumers via **application configurations**; configuration keys can be marked **sensitive** to avoid exposure in query history/command output. (Preview; feature update dated Feb 20, 2026) [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budgets + budget actions (stored procedure invocation) | Snowflake “Budgets” feature | Snowflake docs | Exact SQL/API surface is in the “Custom actions for budgets” + “Cycle-start actions for budgets” docs. We should confirm: required role/privileges + how arguments/context are passed into the proc. [1] |
| Billing invoices (Snowsight UI) | UI + billing artifacts | Snowflake docs | Applies to On Demand accounts; confirm if there’s an API/export or only UI download. [2] |
| Application configurations (Native Apps) | Native App Framework | Snowflake docs | Sensitive configs are explicitly intended to avoid leaking secrets into query history/command output. Confirm how they’re surfaced to Streamlit/React UI and how rotation works. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Budget action pack” for Mission Control**: ship a stored-procedure template + setup guide that lets admins automatically:
   - suspend/resume tagged warehouses
   - set resource monitors / change scaling policies
   - log budget events into an internal `FINOPS.BUDGET_EVENTS` table for audit + analytics
   (Triggered on projected vs actual consumption thresholds.) [1]
2. **Cycle-start “auto-remediation reset”**: provide an opinionated cycle-start stored procedure that reverses prior “budget exceeded” mitigations (re-enable warehouses, restore scaling, notify owners). [1]
3. **Native App secure config onboarding**: add a consumer onboarding step in the Native App to collect required identifiers/URLs/tokens via application configuration keys, using *sensitive* keys for secrets (so we don’t leak into query history). [3]

## Concrete Artifacts

### Stored procedure interface proposal for budget actions (app-side)

Assumption: budget custom actions can call a stored procedure we define; we want a stable signature + structured payload.

```sql
-- Pseudocode / proposed interface
-- (Need to validate exact CALL signature Snowflake passes for budget-triggered procs.)

create or replace procedure FINOPS.BUDGET_ACTION_HANDLER(
    EVENT_TYPE string,              -- e.g. THRESHOLD_REACHED | CYCLE_START
    BUDGET_NAME string,
    THRESHOLD_PERCENT number,
    CONSUMPTION_MODE string,        -- PROJECTED | ACTUAL
    EVENT_TS timestamp_ntz,
    CONTEXT variant                 -- optional: tags, org/account, etc.
)
returns variant
language sql
as
$$
  -- 1) log event
  insert into FINOPS.BUDGET_EVENTS(event_ts, event_type, budget_name, payload)
  values (:EVENT_TS, :EVENT_TYPE, :BUDGET_NAME, object_construct_keep_null(
    'threshold_percent', :THRESHOLD_PERCENT,
    'consumption_mode', :CONSUMPTION_MODE,
    'context', :CONTEXT
  ));

  -- 2) optional: enforce policy (suspend warehouses by tag)
  -- 3) optional: send alert (email/slack via external function / notification integration)

  return object_construct('status','ok');
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact procedure signature + available context for budget-triggered stored procedure calls is unknown from the release note snippet. | We might design an incompatible interface and need refactor. | Read the linked “Custom actions for budgets” + “Cycle-start actions for budgets” docs and capture exact syntax + examples. [1] |
| Invoice access may be UI-only (Snowsight download) and limited to On Demand accounts. | Limits automation and applicability for capacity-contract customers. | Read “Access billing invoices” docs; look for API/export options and role requirements. [2] |
| Native App “sensitive configuration” behavior details (redaction guarantees, auditing, rotation) need confirmation. | Potential secret leakage or missing rotation UX. | Read “Application configuration” docs; confirm how values are stored/accessed and what is redacted. [3] |

## Links & Citations

1. Snowflake Release Note (Feb 24, 2026): User-defined actions for budgets — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Snowflake Release Note (Feb 24, 2026): View invoices in Snowsight — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
3. Snowflake Release Note (Feb 20, 2026): Native Apps Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration

## Next Steps / Follow-ups

- Pull + summarize the full Budgets “custom actions” + “cycle-start actions” docs into a dedicated FinOps note (with exact SQL examples, roles, limits).
- Decide whether Mission Control should implement **budget action handlers** as:
  - pure-SQL stored procs, or
  - Python stored procs (easier logic/testing), or
  - a hybrid that emits events to a table + external worker.
- Check if invoice viewing in Snowsight has any corresponding system tables/views or download endpoints we can hook into.
