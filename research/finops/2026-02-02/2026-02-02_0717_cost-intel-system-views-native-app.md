# FinOps Research Note — Cost intelligence primitives (ACCOUNT_USAGE) + governance knobs (Budgets/Resource Monitors) for a FinOps Native App

- **When (UTC):** 2026-02-02 07:17
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs *portable* cost intelligence (what does a Snowflake account spend, on what, and how fast) plus actionable governance (budgets/monitors) that a platform team can enable without building a separate data pipeline.

## Accurate takeaways
- Snowflake exposes account-level daily credit consumption by service category via `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` (last 365 days), including **SERVICE_TYPE** and a **cloud services rebate** concept. This is the simplest “daily burn-rate” backbone for an app dashboard. (Source: Snowflake docs) [https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history]
- Warehouse-level credit consumption is available via `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, enabling attribution of compute spend to a specific warehouse (useful for chargeback/showback). (Source: Snowflake docs) [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history]
- Snowflake provides **Budgets** as a first-class control surface: a budget defines a monthly spending limit and can be monitored for credit usage against that limit. (Source: Snowflake docs) [https://docs.snowflake.com/en/user-guide/budgets]
- Snowflake provides **Resource Monitors** to help control credit usage (historical feature; separate from Budgets). These are an enforcement/alerting mechanism at the credit-consumption layer. (Source: Snowflake docs) [https://docs.snowflake.com/en/user-guide/resource-monitors]
- For apps that run **containers** (SCS inside a Native App), Snowflake documents specific **cost and governance considerations**—meaning the app should explicitly surface/attribute container-driven usage and provide guardrails to customers. (Source: Snowflake docs) [https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance]

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY`
  - **Type:** view
  - **Grain:** daily
  - **Key columns (per docs):** `SERVICE_TYPE`, credit usage, and cloud services rebate concept.
  - **Use in app:** “Daily total credits by service type” + burn-rate detection.
  - **Source:** [https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history]
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`
  - **Type:** view
  - **Grain:** time windows per warehouse (verify exact columns; commonly includes start/end time + credits used)
  - **Use in app:** warehouse attribution + efficiency heuristics (idle spend, over-provisioning candidates).
  - **Source:** [https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history]
- Budgeting / guardrails:
  - **Budgets (DDL/objects):** confirm exact object types + privilege model in customer account.
  - **Resource monitors:** legacy + still widely used; confirm how they interact with Budgets in current editions.
  - **Sources:** [https://docs.snowflake.com/en/user-guide/budgets], [https://docs.snowflake.com/en/user-guide/resource-monitors]
- Native Apps + containers:
  - **Doc area:** Native Apps → container cost/governance.
  - **App implication:** we should label/attribute container costs separately and educate customers on governance.
  - **Source:** [https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance]

## MVP features unlocked (PR-sized)
1) **Daily burn-rate widget** (ACCOUNT_USAGE-only): show 30/90-day daily credits by `SERVICE_TYPE` with a “slope” alert when today exceeds trailing-14d avg by X%.
2) **Warehouse cost leaderboard**: top-N warehouses by credits for last 7/30 days + a drilldown chart.
3) **Guardrail readiness checklist**: detect whether Budgets and/or Resource Monitors exist/configured; produce “recommended baseline guardrails” guidance.

## Heuristics / detection logic (v1)
- **Burn-rate spike:**
  - `today_credits > avg(last_14_days_credits) * 1.5` (tunable).
- **Service-type anomaly:**
  - For each `SERVICE_TYPE`, compute z-score over trailing window; flag |z| > 3.
- **Warehouse heavy hitters:**
  - Rank warehouses by credits last 30d; for top 5, compute week-over-week growth.
- **Container cost callout (Native Apps + SCS):**
  - If `SERVICE_TYPE` includes `SNOWPARK_CONTAINER_SERVICES` (listed as a possible `SERVICE_TYPE` in metering docs), surface it as a distinct line item and link to governance doc.
  - Source for SERVICE_TYPE list context: [https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history]

## Security/RBAC notes
- These views live under `SNOWFLAKE.ACCOUNT_USAGE` (account-level). Access typically requires elevated privileges (often ACCOUNTADMIN-like capabilities or imported privileges depending on app model). **Confirm required grants** for Native App execution context.
- Budgets and Resource Monitors are account governance controls; any “create/update” workflow must be explicitly consented by customer admin and constrained by least privilege.

## Concrete artifact (SQL draft)
A minimal backbone for the app: normalize daily credits by service type, then optionally join warehouse attribution.

```sql
-- Daily credits by service type (account-wide)
create or replace view FINOPS_APP.PUBLIC.DAILY_CREDITS_BY_SERVICE as
select
  usage_date::date as usage_date,
  service_type,
  sum(credits_used) as credits_used,
  sum(cloud_services_credits) as cloud_services_credits,
  sum(cloud_services_credits_rebate) as cloud_services_credits_rebate
from SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
group by 1,2;

-- Warehouse attribution for the last 30 days
create or replace view FINOPS_APP.PUBLIC.WAREHOUSE_CREDITS_30D as
select
  warehouse_name,
  sum(credits_used) as credits_used
from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
where start_time >= dateadd('day', -30, current_timestamp())
group by 1;
```

Notes:
- Column names for `METERING_DAILY_HISTORY`/`WAREHOUSE_METERING_HISTORY` should be verified in a live account (docs show the views exist; exact column set can evolve).
- In a Native App, schema/database naming and where objects can be created depends on the app’s packaging + privileges.

## Risks / assumptions
- **Column-level assumptions:** The SQL above assumes commonly-used column names (`CREDITS_USED`, etc.). Must validate the exact columns returned by the views in the target Snowflake edition/account.
- **Privileges in Native Apps:** Reading `SNOWFLAKE.ACCOUNT_USAGE` from within a Native App may require specific grant patterns / imported privileges; this needs an explicit design decision.
- **Budgets vs Resource Monitors overlap:** Need to confirm best-practice guidance on when to use Budgets vs Resource Monitors (or both) in 2025/2026.

## Links / references
- `METERING_DAILY_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
- `WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- Budgets: https://docs.snowflake.com/en/user-guide/budgets
- Resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
- Native Apps container cost & governance: https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance
