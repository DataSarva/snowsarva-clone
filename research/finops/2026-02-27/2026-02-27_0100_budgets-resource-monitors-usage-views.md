# Research: FinOps - 2026-02-27

**Time:** 01:00 UTC  
**Topic:** Snowflake FinOps Cost Optimization (Budgets vs Resource Monitors + usage attribution views)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Resource monitors only work for warehouses** (they can monitor warehouse credit usage + related cloud services, and can suspend *user-managed* virtual warehouses). They **cannot track serverless features or AI services**; Snowflake recommends using **Budgets** for those.  
   Source: Snowflake “Working with resource monitors” docs. https://docs.snowflake.com/en/user-guide/resource-monitors

2. **Budgets define a monthly spending limit (in credits)** and send notifications when the limit is *projected* to be exceeded. Budgets can notify via **email**, cloud queues (**SNS / Event Grid / PubSub**), or **webhooks**.  
   Source: Snowflake “Monitor credit usage with budgets” docs. https://docs.snowflake.com/en/user-guide/budgets

3. Budgets have a **refresh interval** (latency between consumption and budget having current data). Default refresh interval is **up to 6.5 hours**; you can reduce to **1 hour** (“low latency budget”), but this increases the budget’s compute cost by a factor of **12**.  
   Source: Snowflake budgets docs. https://docs.snowflake.com/en/user-guide/budgets

4. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credits for the last **365 days**, including:
   - `CREDITS_USED_COMPUTE`
   - `CREDITS_USED_CLOUD_SERVICES`
   - `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only; excludes idle)
   and includes an example query for **idle cost** = compute credits minus attributed-to-queries credits.  
   Source: Snowflake WAREHOUSE_METERING_HISTORY docs. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

5. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` returns **daily** credit usage and includes:
   - `CREDITS_BILLED` (includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES`), and
   - the note that cloud services billing includes an adjustment field (negative).  
   Source: Snowflake METERING_DAILY_HISTORY docs. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by warehouse (1 year). Has `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` to estimate idle vs active. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits and cloud services adjustment; useful for reconciling billed totals. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account-level credits by `SERVICE_TYPE` (e.g., `SNOWPARK_CONTAINER_SERVICES`, `SERVERLESS_TASK`, etc.). (Not deep-extracted in this session; known from docs.) |
| Resource Monitors | Object | n/a | DDL-driven object; enforcement for warehouses only. Docs describe quota + triggers and limits (notify/suspend). |
| Budgets (`BUDGET` class) | Object | n/a | Budgets can group supported objects; can send notifications to queues/webhooks; can call user-defined stored procs at threshold / cycle start. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Controls coverage map” page**: Show which parts of Snowflake spend are covered by enforcement vs monitoring:
   - Warehouses → Resource Monitor (enforce)
   - Serverless & AI (and many service types) → Budgets (monitor + notify)
   Use the budgets “supported services” list to drive a UI checklist.

2. **Idle spend detector (warehouse-level)**: Compute idle credits per warehouse over a time window using `WAREHOUSE_METERING_HISTORY` and surface:
   - top warehouses by idle credits
   - idle % = idle_cost / credits_used_compute
   and recommend tuning auto-suspend / right-sizing.

3. **Budget refresh tier cost advisory**: When user switches to low latency budget (1-hour), show the implied increased compute cost (12× vs default) and require explicit confirmation.

---

## Concrete Artifacts

### SQL: Warehouse idle-cost + idle-percent leaderboard

(Directly aligned to Snowflake’s documented idle-cost approach, extended with percentages and sorting.)

```sql
-- Idle cost by warehouse (last 10 days), with idle percentage.
-- Source idea: Snowflake WAREHOUSE_METERING_HISTORY example query.
-- https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

WITH wh AS (
  SELECT
    warehouse_name,
    SUM(credits_used_compute) AS credits_used_compute,
    SUM(credits_attributed_compute_queries) AS credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -10, CURRENT_DATE())
    AND end_time < CURRENT_DATE()
  GROUP BY 1
)
SELECT
  warehouse_name,
  (credits_used_compute - credits_attributed_compute_queries) AS idle_credits,
  credits_used_compute,
  credits_attributed_compute_queries,
  IFF(credits_used_compute = 0, NULL,
      (credits_used_compute - credits_attributed_compute_queries) / credits_used_compute) AS idle_pct
FROM wh
ORDER BY idle_credits DESC;
```

### ADR (draft): Use Budgets for broad spend visibility; Resource Monitors for hard warehouse guardrails

**Context:** Snowflake spend is split between:
- user-managed warehouses (enforceable), and
- serverless / AI / platform services (not enforceable via resource monitors).

**Decision:**
- Use **Resource Monitors** when the user wants **automated enforcement** (suspend warehouses / notify) at thresholds.
- Use **Budgets** when the user wants **broader monitoring** (including serverless + AI service types) and richer notification targets (webhook/queue), plus the ability to call stored procedures for automated actions.

**Consequences:**
- The app should model two control planes and avoid implying that Resource Monitors cover serverless/AI.
- Budget refresh interval is a tradeoff: shorter refresh can improve responsiveness but has measurable compute cost.

Sources:
- Resource monitors coverage limitation: https://docs.snowflake.com/en/user-guide/resource-monitors
- Budgets notifications + refresh tier: https://docs.snowflake.com/en/user-guide/budgets

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| We assume we can obtain budgets + refresh tier settings programmatically for the app UI. | If not accessible via stable views/APIs, the app may need user-provided configuration or rely on SHOW commands manually. | Investigate Snowflake SQL surface for Budgets (SHOW BUDGETS / BUDGET class APIs) in a follow-up research session. |
| Idle cost computed from `CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES` is a proxy for “idle” and may not perfectly map to business definitions. | Users may disagree on what counts as idle vs background work. | Confirm with Snowflake docs/examples and test against real workloads; expose definition in UI. |
| Budget refresh interval up to 6.5 hours means alerting can lag actual spend. | Users may experience “late” warnings vs real-time expectations. | Add UX copy that budget alerts are forecasting-based and refresh-tier dependent; point to 1-hour low latency option with cost warning. |

---

## Links & Citations

1. Snowflake Budgets: https://docs.snowflake.com/en/user-guide/budgets
2. Snowflake Resource Monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
3. Snowflake ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. Snowflake ACCOUNT_USAGE.METERING_DAILY_HISTORY: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history

---

## Next Steps / Follow-ups

- Research the **SQL interface for Budgets** (SHOW/DESCRIBE, any ACCOUNT_USAGE / ORG_USAGE views, and whether refresh tiers are queryable) to enable app-side introspection.
- Add a “coverage matrix” to app docs: which controls apply to warehouses vs serverless vs AI.
- Extend idle-cost SQL to also include warehouse metadata (size, auto_suspend settings) if accessible, for better recommendations.
