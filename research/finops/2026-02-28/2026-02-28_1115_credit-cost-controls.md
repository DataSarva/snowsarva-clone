# Research: FinOps - 2026-02-28

**Time:** 11:15 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Many Snowflake usage/cost views show credits *consumed* (including cloud services credits) but do not automatically account for the “10% cloud services adjustment”;** to determine credits actually billed for cloud services you query `METERING_DAILY_HISTORY`. 
   - Source: Snowflake “Exploring compute cost” doc notes that cloud services are billed only if daily cloud services usage exceeds 10% of daily warehouse usage and points to `METERING_DAILY_HISTORY` for billed credits. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute)

2. **Budgets are monthly (calendar month) credit-based spending limits**; the budget interval runs **12:00AM UTC on the 1st through 11:59PM UTC on the last day**. Budgets can notify via email, cloud queues (SNS/Event Grid/PubSub), or webhooks. 
   - Source: “Monitor credit usage with budgets”. (https://docs.snowflake.com/en/user-guide/budgets)

3. **Budgets have a refresh interval (latency) up to ~6.5 hours by default;** you can reduce to **1 hour (“low latency budget”)** but that **increases the compute cost of the budget by ~12×** (example given: 1 credit/month → 12 credits/month). 
   - Source: Budgets doc. (https://docs.snowflake.com/en/user-guide/budgets)

4. **Resource monitors only apply to (user-managed) warehouses (plus the cloud services used to support those warehouses)** and cannot track serverless features / AI services; Snowflake explicitly recommends using **budgets** for serverless/AI monitoring. 
   - Source: “Working with resource monitors”. (https://docs.snowflake.com/en/user-guide/resource-monitors)

5. **Resource monitor thresholds are computed using cloud services credits *without* applying the 10% daily adjustment**, so a monitor can trigger based on cloud-services consumption that may not ultimately be billed. 
   - Source: Resource monitor doc (note on adjustment). (https://docs.snowflake.com/en/user-guide/resource-monitors)

6. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credits for the last **365 days** and includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (which excludes idle time). Latency is up to **180 minutes** (and up to **6 hours** for `CREDITS_USED_CLOUD_SERVICES`).
   - Source: WAREHOUSE_METERING_HISTORY view doc. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits for warehouses incl. cloud services; 365 days. `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` excludes idle. Latency up to 3h (6h for CS). (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to compute **billed** cloud services credits (after daily 10% adjustment). Mentioned in “Exploring compute cost”. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Used in examples to analyze cloud services by query type / per-query investigation (compilation, queued time, etc.). (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Converts credits → currency using daily credit price (org-level). Mentioned in “Exploring compute cost”. (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| `RESOURCE MONITOR` | Object | N/A (DDL object) | Controls warehouse credit quotas per interval; actions include NOTIFY/SUSPEND/SUSPEND_IMMEDIATE. (https://docs.snowflake.com/en/user-guide/resource-monitors) |
| `BUDGET` (Snowflake class/object) | Object | N/A (Cost Mgmt feature) | Monthly compute spend limits for account or custom object groups; supports notifications + stored-proc actions. (https://docs.snowflake.com/en/user-guide/budgets) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Billed vs Consumed” dashboard tile:** compute a daily time series showing (a) warehouse consumed credits, (b) cloud services consumed credits, (c) cloud services billed credits (post-adjustment) from `METERING_DAILY_HISTORY`. This clarifies why some views “don’t match the bill”.

2. **Idle-cost spotlight per warehouse:** use `WAREHOUSE_METERING_HISTORY` to calculate (credits used compute − credits attributed to compute queries) as an **idle credits** metric per warehouse, plus a “top idle spenders” list.

3. **Control-plane recommendations engine:** if customers rely on resource monitors for cost control, flag that monitors ignore the daily cloud services adjustment and **recommend** pairing them with budgets for serverless/AI and/or adding buffer thresholds (e.g., 90% notify/suspend) for warehouses.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily “Consumed vs Billed” compute summary (last 30 days)

```sql
-- Purpose:
--   Create a daily summary that distinguishes:
--   - consumed warehouse credits (compute + cloud services)
--   - billed cloud services credits after 10% daily adjustment
-- Sources:
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly)
--   - SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY (daily billed, incl adjustment)
-- Notes:
--   - Many usage views show consumed credits; billed cloud services requires METERING_DAILY_HISTORY.
--   - Consider running ALTER SESSION SET TIMEZONE = UTC when reconciling across schemas.

WITH wh_hourly AS (
  SELECT
    TO_DATE(start_time) AS usage_date,
    SUM(credits_used_compute)         AS wh_credits_compute_consumed,
    SUM(credits_used_cloud_services)  AS wh_credits_cloud_services_consumed,
    SUM(credits_used)                AS wh_credits_total_consumed
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_id > 0  -- skip pseudo warehouses (per Snowflake examples)
  GROUP BY 1
),
mdh AS (
  SELECT
    usage_date,
    credits_used_cloud_services,
    credits_adjustment_cloud_services,
    (credits_used_cloud_services + credits_adjustment_cloud_services) AS cloud_services_credits_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
)
SELECT
  COALESCE(mdh.usage_date, wh_hourly.usage_date) AS usage_date,
  wh_hourly.wh_credits_compute_consumed,
  wh_hourly.wh_credits_cloud_services_consumed,
  wh_hourly.wh_credits_total_consumed,
  mdh.cloud_services_credits_billed
FROM wh_hourly
FULL OUTER JOIN mdh
  ON mdh.usage_date = wh_hourly.usage_date
ORDER BY usage_date DESC;
```

### SQL Draft: Idle credits per warehouse (last 10 days)

```sql
-- Idle credits proxy derived from WAREHOUSE_METERING_HISTORY:
--   idle_credits = credits_used_compute - credits_attributed_compute_queries
-- Source: Example pattern in Snowflake WAREHOUSE_METERING_HISTORY view documentation.

SELECT
  warehouse_name,
  SUM(credits_used_compute) AS credits_compute,
  SUM(credits_attributed_compute_queries) AS credits_attributed_to_queries,
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY 1
ORDER BY idle_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assumption: `METERING_DAILY_HISTORY` is the correct basis for billed cloud services credits in all editions/regions. | If incorrect, billed-vs-consumed tile could mislead. | Confirm with Snowflake docs + compare with invoice/usage statements in a test account. (Doc reference points here explicitly.) (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| Assumption: Using `WAREHOUSE_METERING_HISTORY` summed by `TO_DATE(start_time)` aligns with Snowflake’s daily billing boundaries (UTC). | Could create day-boundary off-by-one when session timezone isn’t UTC. | Follow Snowflake guidance: set session timezone to UTC when reconciling across schemas. (https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history) |
| Latency: `ACCOUNT_USAGE` views can lag (3h typical; 6h for CS columns). | Near-real-time “today” numbers may be incomplete; alerts could be delayed. | In UI/API, annotate freshness and/or use Information Schema equivalents where appropriate (docs note Info Schema can be faster). (https://docs.snowflake.com/en/user-guide/cost-exploring-compute) |
| Budgets low-latency tier costs 12× more than default. | Over-eager FinOps monitoring could increase spend. | Only enable low-latency budgets temporarily; surface estimated budget overhead cost. (https://docs.snowflake.com/en/user-guide/budgets) |
| Resource monitor ignores 10% CS adjustment. | Quota actions may trigger earlier than billed reality; could cause unnecessary suspends. | Recommend buffers (e.g. suspend at 90%) and pair with billed metrics from `METERING_DAILY_HISTORY`. (https://docs.snowflake.com/en/user-guide/resource-monitors) |

## Links & Citations

1. Exploring compute cost (Snowsight + ACCOUNT_USAGE/ORG_USAGE; cloud services 10% adjustment; billed credits via `METERING_DAILY_HISTORY`; mentions `USAGE_IN_CURRENCY_DAILY`) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute
2. Monitor credit usage with budgets (monthly UTC interval; refresh interval; low latency budget cost multiplier; notification targets; supported services list) — https://docs.snowflake.com/en/user-guide/budgets
3. Working with resource monitors (warehouses only; actions; schedule reset at 12:00AM UTC; ignores 10% CS adjustment) — https://docs.snowflake.com/en/user-guide/resource-monitors
4. `WAREHOUSE_METERING_HISTORY` view (columns, latency; idle-cost example; timezone reconciliation note) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Pull + cite Snowflake docs for `METERING_DAILY_HISTORY` and `USAGE_IN_CURRENCY_DAILY` directly, then extend the artifact SQL to optionally produce currency metrics org-wide.
- Identify if/how budgets expose programmatic query surfaces (views/events) for “projected exceed” vs “actual” to integrate into the native app.
- Decide product UX: emphasize “consumed vs billed” distinction anywhere cloud services is shown.
