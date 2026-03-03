# Research: FinOps - 2026-03-03

**Time:** 10:01 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse (up to the last 365 days) and includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and their sum `CREDITS_USED` (note: may exceed billed credits due to cloud services adjustments). It also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` which excludes idle time. 
2. For “credits actually billed” (including the **daily cloud services adjustment**), Snowflake points to `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` and the `CREDITS_BILLED` column (daily granularity, up to the last 365 days).
3. Resource monitors are a Snowflake object that can **notify and/or suspend warehouses** based on credit quota thresholds, but they are for **warehouse-related** usage only; they are **not** for serverless features and AI services (Snowflake recommends using **Budgets** for those).
4. Budgets define a **monthly** spending limit (in credits) for an account or a group of supported objects; budgets can notify via email, cloud queues, or **webhooks**, and can call user-defined stored procedures at thresholds or at cycle start.
5. Budgets have a “refresh interval” (latency) concept: default is “up to ~6.5 hours”; “low latency budgets” can reduce to **1 hour**, but Snowflake notes this increases the compute cost of the budget by a factor of **12**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes `CREDITS_USED_*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (idle excluded). Latency up to 180 min; cloud services column up to 6 hours. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits by `SERVICE_TYPE`; includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`. Latency up to 180 min. |
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | `ACCOUNT_USAGE` | Read resource monitor configs + thresholds and current-cycle usage (variants). |
| Resource Monitors (object) | Object | Snowflake object | Controls/alerts for warehouses; not for serverless/AI. |
| Budgets (class/object) | Object | Snowflake cost management feature | Monthly credit “spending limit” with forecasting + integrations + stored procedure actions. |

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Controls coverage” UI + recommendations:** detect whether an account is relying on resource monitors (warehouses) vs budgets (serverless/AI) and show gaps (e.g., warehouse-only controls but no budget coverage for AI_SERVICES / serverless).
2. **Near-real-time spend tiles:** show a “warehouse hourly” tile from `WAREHOUSE_METERING_HISTORY` alongside the “billed daily” tile from `METERING_DAILY_HISTORY`, explicitly labeling their different semantics and latencies.
3. **Action wiring (extensible):** generate a set of “recommended actions” that map to (a) resource monitor thresholds and (b) budget webhooks / stored procedure custom actions, with clear guidance on what each can/can’t control.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL draft: Daily spend model with reconciliation hints

Goal: produce a daily table that can drive the app’s “billed truth” (daily, per service type) and optionally reconcile warehouse hourly sums.

```sql
-- Create a normalized daily spend fact (credits) based on Snowflake-billed accounting.
-- This is the best foundation for: budgets alignment, monthly reports, and account-wide totals.

CREATE OR REPLACE VIEW FINOPS.COST_FACT_DAILY AS
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed,
  -- convenience
  (credits_used_compute + credits_used_cloud_services)              AS credits_used_unadjusted,
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services_component
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -365, CURRENT_DATE());

-- Optional: a *warehouse* hourly lens to support “spend velocity”, idle analysis, and intra-day alerts.
-- (Not billed truth; cloud services adjustments happen daily.)
CREATE OR REPLACE VIEW FINOPS.WAREHOUSE_CREDITS_HOURLY AS
SELECT
  start_time,
  end_time,
  warehouse_id,
  warehouse_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP());
```

### ADR sketch: “Controls” layer (Resource Monitors vs Budgets)

**Context:** Snowflake cost control primitives differ by cost category. Resource monitors can suspend/notify warehouses but don’t cover serverless/AI. Budgets can cover broader services and can call stored procedures + integrate via webhook/queue.

**Decision:** In the Native App, represent “controls” as a normalized model:
- `CONTROL_TYPE`: `RESOURCE_MONITOR` | `BUDGET`
- `COVERAGE`: `WAREHOUSE_ONLY` | `MULTI_SERVICE`
- `ACTION_SURFACE`: `SUSPEND_WAREHOUSE` | `NOTIFY_EMAIL` | `WEBHOOK` | `CLOUD_QUEUE` | `STORED_PROC`

**Consequence:** The app can:
- recommend the right control based on spend category,
- avoid promising enforcement where Snowflake doesn’t support it,
- route actions to integrations that customers already use (PagerDuty/Teams/Slack via webhook).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `METERING_DAILY_HISTORY.CREDITS_BILLED` is the canonical “what you pay” number for all cases | Misleading totals for special billing agreements | Validate against customer invoice exports / ORG currency views where available. |
| Treating hourly warehouse credits as “real-time spend” | Customers may conflate unadjusted usage with billed usage | UI must label semantics: hourly is operational; daily billed is accounting. |
| Budgets 1-hour refresh tier cost tradeoff acceptable for most customers | Could introduce noticeable overhead or surprise | Offer guidance + default to standard tier; show the budget’s own compute cost if accessible. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY view (hourly warehouse usage; idle cost example; latency notes): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. METERING_DAILY_HISTORY view (daily billed credits + cloud services adjustments; service types): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. RESOURCE_MONITORS view (monitor configuration + thresholds + used/remaining credits fields): https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors
4. Working with resource monitors (warehouse-only limitation; cloud services adjustment note; thresholds/actions): https://docs.snowflake.com/en/user-guide/resource-monitors
5. Budgets (monthly spending limit; webhooks/queues; stored proc actions; refresh tiers + cost factor): https://docs.snowflake.com/en/user-guide/budgets

## Next Steps / Follow-ups

- Add a “controls inventory” collector that reads `ACCOUNT_USAGE.RESOURCE_MONITORS` and maps monitors → warehouses + thresholds.
- Add a “budget inventory” collector (objects + refresh tier + notification integrations) and display which service types are covered.
- Spec the UI labels for hourly vs daily billed credits to prevent misinterpretation.
