# FinOps Research Note — Budgets vs Resource Monitors: alerting + integrations we can productize in the FinOps Native App

- **When (UTC):** 2026-02-02 19:06
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** Budgets + Resource Monitors are Snowflake-native “control plane” levers for cost governance. A FinOps Native App can (a) inventory current controls, (b) detect misconfiguration / missing alert coverage, (c) guide set-up for notifications (email/queue/webhook), and (d) provide an audit trail of budget notifications via `NOTIFICATION_HISTORY`.

## Accurate takeaways
- **Budgets** set a *monthly* credit spending limit (alerting/notification-only) for the whole account (account budget) or a tagged/curated group of supported objects (custom budgets). The monthly interval is fixed to **calendar month in UTC**. If activated after month start, account budget backfills from month start; custom budget backfill behavior depends on whether resources were added by tag vs individually.  
  Source: https://docs.snowflake.com/en/user-guide/budgets
- Budgets send **daily alert notifications** when spending is *projected* (forecasted) to exceed the budget’s spending limit; notifications can be delivered by **email**, **cloud queues** (SNS / Event Grid / PubSub), or **webhooks** (e.g., Slack/Teams/PagerDuty).  
  Source: https://docs.snowflake.com/en/user-guide/budgets and https://docs.snowflake.com/en/user-guide/budgets/notifications
- Budget notification timing is configurable: default trigger starts when projection is **>110%** of the spending limit (i.e., “10% above”); you can set a custom threshold percentage via the `BUDGET` class method `SET_NOTIFICATION_THRESHOLD` (reset to default by setting `110`).  
  Source: https://docs.snowflake.com/en/user-guide/budgets/notifications
- Budget notifications to queues/webhooks contain a JSON message; Snowflake supports querying notification history via `NOTIFICATION_HISTORY`, and **budget notifications have `message_source = 'BUDGET'`**.  
  Source: https://docs.snowflake.com/en/user-guide/budgets/notifications
- **Resource Monitors** are the legacy/warehouse-focused control: they monitor credit usage by **user-managed virtual warehouses**, can define up to **5 thresholds**, can email notify, and can optionally **suspend** a warehouse at a threshold.  
  Source: https://docs.snowflake.com/en/user-guide/cost-controlling

## Snowflake objects & data sources (verify in target account)
- **Budgets (feature + RBAC):**
  - Uses Snowflake-provided roles for cost features; documented application roles for account budget include `BUDGET_VIEWER` and `BUDGET_ADMIN`.
  - Custom budgets have instance roles (per-budget) including `VIEWER` and `ADMIN`.
  - Documented additional privileges/roles include Snowflake DB role `USAGE_VIEWER`, DB role `SNOWFLAKE.BUDGET_CREATOR`, privilege `CREATE SNOWFLAKE.CORE.BUDGET`, and per-object `APPLYBUDGET` to add/remove objects.
  - View(s) / functions: `NOTIFICATION_HISTORY` (function) for notifications audit; exact catalog/schema name depends on Snowflake (commonly exposed via `TABLE(…)` usage).  
  Source: https://docs.snowflake.com/en/user-guide/budgets and https://docs.snowflake.com/en/user-guide/budgets/notifications
- **Resource Monitors:**
  - System command surface: `SHOW RESOURCE MONITORS`, `SHOW WAREHOUSES` (not re-verified in this pull; treat as standard Snowflake admin surface).
  - Monitoring coverage: warehouse compute only (per cost-controlling doc).  
  Source: https://docs.snowflake.com/en/user-guide/cost-controlling

## MVP features unlocked (PR-sized)
1) **“Cost controls coverage” scanner:** detect whether (a) account budget is activated, (b) custom budgets exist for key tags/workloads, (c) warehouses are covered by resource monitors *or* budgets (and whether any notification destinations exist).
2) **“Budget notifications audit” view:** show last N notifications, delivery destination (integration name), and budget metadata in a single UI panel.
3) **Guided setup UX:** generate SQL snippets for (a) creating notification integrations, (b) attaching integrations to budgets, (c) setting thresholds.

## Heuristics / detection logic (v1)
- **Budget notification coverage:**
  - If budgets exist but **no notification integration is attached** (or no email recipients set), flag as “budget will not notify”.
  - If threshold is set very high (e.g., >110%) flag as “late warning”. (Some teams may intentionally do this; treat as informational.)
- **Resource monitor coverage:**
  - Warehouses without a resource monitor (and without a budget custom grouping that includes warehouses) = potential gap.
  - Warehouses with resource monitor but no suspend threshold = “monitoring only” (again informational).
- **Forecast reliability (UX):** budgets are forecast-based and daily; show that alerts are “projection” not “actual”, and clarify month is **UTC**.

## Concrete artifact — SQL draft (notification audit)
> Goal: provide an app-owned view that normalizes budget notifications across destinations.

```sql
-- Budget notification audit (queue/webhook/email events) from NOTIFICATION_HISTORY.
-- Filter by time range + message_source='BUDGET'.
-- NOTE: signature/columns of NOTIFICATION_HISTORY should be validated in target account.

create or replace view FINOPS.BUDGET_NOTIFICATION_AUDIT as
select
  -- normalize the integration identity if available
  integration_name,
  message_source,
  event_timestamp,
  status,
  error_message,
  message
from table(notification_history(
  -- examples often take a time range; adjust to your environment
  -- start_time => dateadd('day', -30, current_timestamp()),
  -- end_time   => current_timestamp()
))
where message_source = 'BUDGET'
  and event_timestamp >= dateadd('day', -30, current_timestamp());
```

If we want to enrich by budget name / threshold / recipients, we likely need to call Budget class methods like:
- `<budget_name>!GET_NOTIFICATION_INTEGRATIONS()`
- `<budget_name>!GET_NOTIFICATION_INTEGRATION_NAME()`
- `<budget_name>!SET_NOTIFICATION_THRESHOLD(<pct>)`

…which suggests a stored procedure / task to snapshot budget configuration into app tables for join-friendly reporting.

## Security/RBAC notes
- Budgets are governed by Snowflake cost-management roles + privileges. The app should:
  - Operate read-only by default (viewer mode), and
  - Require an explicit “admin mode” workflow to emit `GRANT`/`CREATE`/`ALTER` statements.
- For queue/webhook notifications: the docs note you must `GRANT USAGE ON NOTIFICATION INTEGRATION … TO APPLICATION SNOWFLAKE` (Snowflake-managed), and for secrets-backed webhook integrations you must grant `READ` on the secret plus DB/Schema `USAGE` to the Snowflake application.  
  Source: https://docs.snowflake.com/en/user-guide/budgets/notifications

## Risks / assumptions
- **Assumption:** `NOTIFICATION_HISTORY` is available and queryable in all editions where budgets are available; exact function signature/columns must be validated.
- **Assumption:** We can reliably inventory budgets + their config via SHOW/DESCRIBE or class method calls from a stored procedure; docs show method names but not full operational ergonomics in excerpts.
- **UX risk:** Budget notifications are *forecast-based daily alerts*; users might expect real-time or exact-at-threshold behavior.

## Links / references
- Snowflake docs — Monitor credit usage with budgets: https://docs.snowflake.com/en/user-guide/budgets
- Snowflake docs — Notifications for budgets: https://docs.snowflake.com/en/user-guide/budgets/notifications
- Snowflake docs — Controlling cost (Budgets vs Resource Monitors overview): https://docs.snowflake.com/en/user-guide/cost-controlling
- Snowflake Well-Architected Framework (FinOps / cost optimization guide): https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
