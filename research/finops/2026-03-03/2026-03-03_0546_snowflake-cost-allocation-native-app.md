# Research: FinOps - 2026-03-03

**Time:** 05:46 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost allocation primitives for a Native App)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for the last **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query execution only; excludes idle time). Latency can be up to **180 minutes** (cloud services up to **6 hours**). [WAREHOUSE_METERING_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes fields useful for cost attribution and optimization signals such as `WAREHOUSE_NAME`, `QUERY_TAG`, `BYTES_SCANNED`, `TOTAL_ELAPSED_TIME`, queue times, and `CREDITS_USED_CLOUD_SERVICES` (note: this is cloud services credits used, and may not match billed credits). [QUERY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/query_history)
3. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` identifies **direct** tag associations between objects and tags; it explicitly does **not** include tag inheritance. Latency may be up to **120 minutes**. [TAG_REFERENCES](https://docs.snowflake.com/en/sql-reference/account-usage/tag_references)
4. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` returns daily credits by `SERVICE_TYPE` (including `WAREHOUSE_METERING`, `SNOWPARK_CONTAINER_SERVICES`, `AI_SERVICES`, etc.) and includes `CREDITS_BILLED` and cloud services adjustment (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`). Latency may be up to **180 minutes**. [METERING_DAILY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history)
5. Resource monitors can monitor/suspend **warehouses only** (not serverless/AI services). They track credits consumed (including cloud services used to support warehouses) and can notify/suspend at thresholds; monitors are interval-based and not designed for strict hourly enforcement. [Resource Monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)
6. Budgets define **monthly** spending limits for an account or group of objects; budgets can notify via email, cloud queues, or webhooks, and can call **stored procedures** at thresholds / cycle start. Default refresh latency is up to **6.5 hours**; “low latency budgets” can refresh hourly but increase budget compute cost by a factor of **12**. [Budgets](https://docs.snowflake.com/en/user-guide/budgets)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (compute + cloud services). Includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (execution only), enabling explicit idle-cost computation. Latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata including `QUERY_TAG`, `WAREHOUSE_NAME`, elapsed/queue times, bytes scanned, and `CREDITS_USED_CLOUD_SERVICES`. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct object↔tag associations; *no inheritance*. Useful for “cost by tag” when combined with object identity mapping. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits by service type, includes `CREDITS_BILLED` and cloud services adjustment for billed reconciliation. |
| Resource monitors | Object | N/A (DDL + UI) | Warehouse-only credit controls (notify/suspend). Not for serverless/AI services. |
| Budgets | Object / Class | N/A (DDL + UI) | Monthly budgets for account or tagged/object groups; supports notifications and stored-procedure actions. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle cost leaderboard (warehouse-level):** compute idle credits as `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` per warehouse per day/hour and surface “always-on” warehouses and mis-sized multi-cluster warehouses. (Directly supported by `WAREHOUSE_METERING_HISTORY`.)
2. **Query-tag cost attribution (team/product):** enforce/apply `QUERY_TAG` policy + show spend by query tag (and by warehouse) using `QUERY_HISTORY` + warehouse hourly metering to approximate/allocate compute. Pair with a “missing query_tag” alert.
3. **Budget + action hooks integration:** generate a packaged stored procedure template that customers can attach to budgets (threshold/cycle-start) to automatically suspend non-prod warehouses or notify Slack/webhook endpoints.

## Concrete Artifacts

### SQL draft: hourly warehouse compute vs query-attributed compute + idle credits

This is a minimal “FinOps core table” query you can materialize into an internal cost mart for the Native App.

```sql
-- Hourly warehouse cost + idle cost (compute credits only)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--  - CREDITS_USED is compute+cloud services used (not necessarily billed)
--  - billed credits are best reconciled via METERING_DAILY_HISTORY

ALTER SESSION SET TIMEZONE = 'UTC';

WITH wh AS (
  SELECT
    START_TIME,
    END_TIME,
    WAREHOUSE_ID,
    WAREHOUSE_NAME,
    CREDITS_USED_COMPUTE,
    CREDITS_USED_CLOUD_SERVICES,
    CREDITS_USED,
    CREDITS_ATTRIBUTED_COMPUTE_QUERIES
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP())
)
SELECT
  START_TIME,
  END_TIME,
  WAREHOUSE_NAME,
  CREDITS_USED_COMPUTE,
  CREDITS_ATTRIBUTED_COMPUTE_QUERIES,
  (CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES) AS CREDITS_IDLE_COMPUTE_EST,
  CREDITS_USED_CLOUD_SERVICES
FROM wh
ORDER BY START_TIME DESC, WAREHOUSE_NAME;
```

### SQL draft: daily billed credits (for reconciliation + “true spend”)

```sql
-- Daily billed credits by service type
-- Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- This is the right primitive for “what was billed” (includes cloud services adjustment).

ALTER SESSION SET TIMEZONE = 'UTC';

SELECT
  USAGE_DATE,
  SERVICE_TYPE,
  CREDITS_USED_COMPUTE,
  CREDITS_USED_CLOUD_SERVICES,
  CREDITS_ADJUSTMENT_CLOUD_SERVICES,
  CREDITS_BILLED
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY USAGE_DATE DESC, SERVICE_TYPE;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` and `QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES` are “credits used” and may exceed billed credits (cloud services adjustment) | If we report “true spend”, we may overstate cost unless reconciled against billed primitives | Use `METERING_DAILY_HISTORY.CREDITS_BILLED` for billed reconciliation and clearly label metrics as “used” vs “billed”. [WAREHOUSE_METERING_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history), [QUERY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/query_history), [METERING_DAILY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history) |
| Account Usage views have latency (2–6+ hours depending on view/column) | “Near real time” dashboards will be stale; alerts may lag | Document expected freshness; optionally pair with event-driven signals or “low latency budgets” where available. [WAREHOUSE_METERING_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history), [TAG_REFERENCES](https://docs.snowflake.com/en/sql-reference/account-usage/tag_references), [Budgets](https://docs.snowflake.com/en/user-guide/budgets) |
| `TAG_REFERENCES` excludes tag inheritance | Cost-by-tag based on inheritance will be incomplete if we only use this view | If inherited tags matter, supplement with INFORMATION_SCHEMA table function `TAG_REFERENCES` (not researched in this slice) and/or enforce direct tagging for cost allocation. [TAG_REFERENCES](https://docs.snowflake.com/en/sql-reference/account-usage/tag_references) |
| Resource monitors do not cover serverless/AI services | Cost controls may miss meaningful spend categories (SCS, Cortex, etc.) | Use budgets for broader service types; show service-type breakdown from `METERING_DAILY_HISTORY`. [Resource Monitors](https://docs.snowflake.com/en/user-guide/resource-monitors), [Budgets](https://docs.snowflake.com/en/user-guide/budgets) |
| Low latency budgets cost more compute | Customers might enable hourly refresh and be surprised by budget overhead | Make refresh-tier guidance explicit and expose estimated budget overhead. [Budgets](https://docs.snowflake.com/en/user-guide/budgets) |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
4. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
5. https://docs.snowflake.com/en/user-guide/resource-monitors
6. https://docs.snowflake.com/en/user-guide/budgets

## Next Steps / Follow-ups

- Draft a concrete “cost allocation model” for the Native App: define which metrics are *billed*, *used*, and *allocated*, and how we reconcile per-service and per-warehouse totals.
- Research: best-practice patterns for enforcing `QUERY_TAG` (role-based session parameter enforcement, driver configs) + any Snowflake-native policy mechanisms.
- Research: organization-wide views (`ORGANIZATION_USAGE`) for multi-account/ORG rollups (important for enterprise FinOps rollups).
