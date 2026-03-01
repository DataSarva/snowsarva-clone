# Research: FinOps - 2026-03-01

**Time:** 04:23 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake Budgets **custom actions** can automatically call a **stored procedure** when a spending threshold is reached; each action specifies whether it triggers on **projected** or **actual** credit consumption, and a budget supports **up to 10 custom actions**. [1][4]

2. A stored procedure invoked by a **budget custom action** must (a) run with **owner’s rights** (not caller’s rights), (b) complete within **30 minutes**, (c) have **no OUTPUT argument**, and (d) be **idempotent** because Snowflake retries failed actions **once**. The procedure (and its parent DB/schema) must be granted `USAGE` to the `APPLICATION SNOWFLAKE`. [4]

3. Budgets **cycle-start actions** can call a stored procedure when the budget cycle restarts (spend reset to 0 at start of monthly period). You can configure **one** cycle-start action per budget via `SET_CYCLE_START_ACTION`. [2][5]

4. Snowflake executes budget actions via **tasks**; custom actions follow a `BUDGET_CUSTOM_ACTION_TRIGGER_AT_%` naming convention, and cycle-start uses a task named `_budget_cycle_start_task`. This means action observability can be built from `SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY` joined to `SNOWFLAKE.ACCOUNT_USAGE.CLASS_INSTANCES` (class `BUDGET`). [4][5]

5. Native Apps can request consumer-provided values via **application configurations** (key/value). Config definitions are created via `ALTER APPLICATION SET CONFIGURATION DEFINITION ...`; consumers set values via `ALTER APPLICATION ... SET CONFIGURATION ... VALUE = ...`. Configs can be marked **SENSITIVE=TRUE** (STRING only) to redact values from query history and avoid surfacing them in `SHOW CONFIGURATIONS`, `DESCRIBE CONFIGURATION`, `INFORMATION_SCHEMA`, or `ACCOUNT_USAGE`. [3][6]

6. On Demand customers can view/download **billing invoices** in Snowsight (Admin » Billing » Invoices). Access requires either `GLOBALORGADMIN` in the organization account, or `ACCOUNTADMIN` + `ORGADMIN` in an account with ORGADMIN enabled. [7][8]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budget custom actions | Budget class capability | Docs | Configured via `...!ADD_CUSTOM_ACTION(...)` using `SYSTEM$REFERENCE('PROCEDURE', '<fq_proc_sig>')`. [4] |
| Budget cycle-start action | Budget class capability | Docs | Configured via `...!SET_CYCLE_START_ACTION(...)`; one per budget. [5] |
| `SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY` | View | `ACCOUNT_USAGE` | Used to monitor execution of budget action tasks (custom + cycle-start). [4][5] |
| `SNOWFLAKE.ACCOUNT_USAGE.CLASS_INSTANCES` | View | `ACCOUNT_USAGE` | Join to `TASK_HISTORY.instance_id` to resolve budget instance name (`class_name='BUDGET'`). [4][5] |
| Application configurations | Native App Framework object | Docs | Created/managed via `ALTER APPLICATION SET CONFIGURATION DEFINITION/VALUE ...`; supports `SENSITIVE=TRUE`. [6] |
| Billing invoices (Snowsight) | UI capability | Docs | On Demand only; roles/entrypoint documented. [7][8] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Budget Action Pack” generator inside the Native App**: ship a small set of stored procedure templates (SQL/JS) plus copy/paste `GRANT USAGE ... TO APPLICATION SNOWFLAKE` commands and `ADD_CUSTOM_ACTION` snippets. This turns budgets into an automation bus for FinOps guardrails. [4]

2. **Action observability dashboard**: materialize a view that tracks budget-action task runs (success/failure/attempts) by joining `TASK_HISTORY` + `CLASS_INSTANCES`. Surface it as “Guardrail execution history” for trust + debugging. [4][5]

3. **Secure notification configuration**: use Native App application configurations to request values like `email_integration_name`, `slack_webhook_url`, or “Ops escalation list”. Mark secrets as `SENSITIVE=TRUE` to avoid leakage in query history and metadata views. [6]

## Concrete Artifacts

### ADR (Draft): Budget-driven guardrails via Budgets Actions + Native App Configurations

**Status:** Draft  
**Decision:** Use Snowflake Budgets custom actions + cycle-start actions as the *primary* automation trigger mechanism for FinOps guardrails, with Native App application configurations used for consumer-provided routing/secret values.

**Why:**
- Budgets can trigger stored procedures on projected/actual thresholds (10 actions) and at cycle-start; this is sufficient for most “autopilot” guardrails and reversals. [1][2][4][5]
- Native App configurations provide a first-class, safer channel to collect consumer inputs and secrets (sensitive string redaction). [6]

**Key constraints to design around:**
- Stored procedure requirements: owner’s rights, <=30 minutes, no OUTPUT arg; must be idempotent (retry once). [4][5]
- The procedure (and DB/schema) must be granted `USAGE` to `APPLICATION SNOWFLAKE` (special application identity). [4][5]

**Implementation shape:**
- The Native App ships:
  - a “Guardrail library” schema (tables/views) for audit + state
  - procedure templates (or a setup wizard that creates them)
  - configuration definitions for routing/secret values (some sensitive)
- The consumer/admin wires budgets to those procedures using `...!ADD_CUSTOM_ACTION` and `...!SET_CYCLE_START_ACTION`.

**Open questions:**
- What *minimum* privileges should the guardrail procedures have to suspend/resume warehouses or alter monitors without becoming a “god mode” risk? (Likely require a dedicated role, with least-privilege grants, and a narrow allowlist of warehouses.)

---

### SQL Draft: Guardrail audit table + example budget custom action

```sql
-- 1) Audit table (consumer-owned; keep it in a dedicated FINOPS DB)
CREATE SCHEMA IF NOT EXISTS finops.guardrails;

CREATE TABLE IF NOT EXISTS finops.guardrails.budget_action_events (
  event_ts            TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  event_type          STRING          NOT NULL,  -- THRESHOLD | CYCLE_START | MANUAL
  budget_name         STRING          NULL,
  action_kind         STRING          NULL,      -- SUSPEND_WH | RESUME_WH | NOTIFY | LOG_ONLY
  threshold_type      STRING          NULL,      -- PROJECTED | ACTUAL
  threshold_pct       NUMBER(5,2)     NULL,
  payload             VARIANT         NULL,
  invocation_id       STRING          NULL,
  status              STRING          NOT NULL,  -- STARTED | OK | ERROR
  error_message       STRING          NULL
);

-- 2) Example stored procedure skeleton (must be EXECUTE AS OWNER) [4]
-- NOTE: Signature/types must match budget action constraints (simple required arg types) [4]
CREATE OR REPLACE PROCEDURE finops.guardrails.on_budget_threshold(
  budget_name       STRING,
  threshold_type    STRING,
  threshold_pct     NUMBER(5,2),
  warehouse_name    STRING,
  email_integration STRING,
  notify_email      STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_invocation_id STRING DEFAULT UUID_STRING();
BEGIN
  INSERT INTO finops.guardrails.budget_action_events(
    event_type, budget_name, action_kind, threshold_type, threshold_pct, payload, invocation_id, status
  )
  SELECT
    'THRESHOLD', budget_name, 'SUSPEND_WH', threshold_type, threshold_pct,
    OBJECT_CONSTRUCT('warehouse', warehouse_name, 'notify_email', notify_email),
    v_invocation_id, 'STARTED';

  -- Idempotency guard (budget actions can be retried once) [4]
  IF EXISTS (
    SELECT 1
    FROM finops.guardrails.budget_action_events
    WHERE invocation_id = v_invocation_id AND status = 'OK'
  ) THEN
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'skipped', TRUE);
  END IF;

  EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || IDENTIFIER(:warehouse_name) || ' SUSPEND';

  -- Optional: notify via SYSTEM$SEND_EMAIL (requires email integration)
  -- CALL SYSTEM$SEND_EMAIL(:email_integration, :notify_email, 'Budget threshold reached', 'Warehouse suspended');

  UPDATE finops.guardrails.budget_action_events
    SET status = 'OK'
    WHERE invocation_id = v_invocation_id AND status = 'STARTED';

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'invocation_id', v_invocation_id);
EXCEPTION
  WHEN OTHER THEN
    UPDATE finops.guardrails.budget_action_events
      SET status = 'ERROR', error_message = SQLERRM
      WHERE invocation_id = v_invocation_id AND status = 'STARTED';
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'invocation_id', v_invocation_id, 'error', SQLERRM);
END;
$$;

-- 3) Required grants to allow Budgets automation (SNOWFLAKE application) to execute the procedure [4]
GRANT USAGE ON DATABASE finops TO APPLICATION SNOWFLAKE;
GRANT USAGE ON SCHEMA finops.guardrails TO APPLICATION SNOWFLAKE;
GRANT USAGE ON PROCEDURE finops.guardrails.on_budget_threshold(
  STRING, STRING, NUMBER, STRING, STRING, STRING
) TO APPLICATION SNOWFLAKE;

-- 4) Wire the procedure as a custom action on a budget using ADD_CUSTOM_ACTION [4]
-- (replace budget_db.sch.my_budget with your budget instance)
CALL budget_db.sch.my_budget!ADD_CUSTOM_ACTION(
  SYSTEM$REFERENCE(
    'PROCEDURE',
    'finops.guardrails.on_budget_threshold(string, string, number, string, string, string)'
  ),
  ARRAY_CONSTRUCT('MY_BUDGET', 'ACTUAL', 90, 'ANALYST_WH', 'my_int', 'admin@example.com'),
  'ACTUAL',
  90
);
```

### SQL Draft: Action-run observability view (TASK_HISTORY + CLASS_INSTANCES)

```sql
-- Track budget action task executions (success/failure) for a named budget.
-- Custom actions use tasks named like BUDGET_CUSTOM_ACTION_TRIGGER_AT_% [4]
-- Cycle-start uses a task named _budget_cycle_start_task [5]

WITH budgets AS (
  SELECT id, name
  FROM snowflake.account_usage.class_instances
  WHERE class_name = 'BUDGET'
), task_runs AS (
  SELECT
    th.completed_time,
    th.state,
    th.name                     AS task_name,
    th.query_id,
    th.error_code,
    th.error_message,
    th.instance_id
  FROM snowflake.account_usage.task_history th
  WHERE th.completed_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
    AND (
      th.name ILIKE 'BUDGET_CUSTOM_ACTION_TRIGGER_AT_%'
      OR th.name ILIKE '_budget_cycle_start_task'
    )
)
SELECT
  tr.completed_time,
  b.name            AS budget_name,
  tr.task_name,
  tr.state,
  tr.query_id,
  tr.error_code,
  tr.error_message
FROM task_runs tr
JOIN budgets b
  ON tr.instance_id = b.id
ORDER BY tr.completed_time DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Budget actions run via tasks; long-running or non-idempotent procedures may cause repeated mitigations or inconsistent state (actions retried once). | Unintended warehouse suspensions/resumes; alert spam. | Enforce idempotency keys + “already applied” state, and keep procedures fast (<30 minutes). [4][5] |
| `APPLICATION SNOWFLAKE` `USAGE` grants are required and must be re-granted after procedure updates. | Guardrails silently stop working after changes. | Add a “health check” query in the app + docs for re-grant step. [4][5] |
| App configurations are Preview and may evolve; sensitive semantics must be validated in practice. | Setup UX might break or expose secrets if behavior changes. | Feature-gate configuration flows; track release notes; add a fallback path (manual secret objects / external integrations) if configs unavailable. [3][6] |
| Invoices are On Demand-only and appear UI-first. | Limited applicability for capacity-contract customers; hard to automate. | Treat invoice UX as optional; prioritize usage-based cost metrics from metering/usage views. [7][8] |

## Links & Citations

1. Snowflake release notes — Budgets user-defined actions (summary): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Snowflake release notes — Budgets cycle-start actions (same page; links to docs): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
3. Snowflake release notes — Native Apps configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Snowflake Docs — Custom actions for budgets: https://docs.snowflake.com/en/user-guide/budgets/custom-actions
5. Snowflake Docs — Cycle-start actions for budgets: https://docs.snowflake.com/en/user-guide/budgets/cycle-start-actions
6. Snowflake Docs — Application configuration (Native Apps): https://docs.snowflake.com/en/developer-guide/native-apps/app-configuration
7. Snowflake release notes — View invoices in Snowsight: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
8. Snowflake Docs — Access billing invoices: https://docs.snowflake.com/en/user-guide/billing-invoices

## Next Steps / Follow-ups

- Confirm the *exact* argument payload Budgets passes to procedures (if any implicit args exist) vs only what is specified in `ARRAY_CONSTRUCT(...)` when adding actions.
- Draft a least-privilege “Guardrails Role” checklist (what grants are needed to suspend/resume specific warehouses) and an allowlist design.
- Evaluate whether the Native App should auto-create guardrail procedures (setup step) vs just generating templates for admins.
