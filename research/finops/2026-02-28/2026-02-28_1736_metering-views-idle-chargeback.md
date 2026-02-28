# Research: FinOps - 2026-02-28

**Time:** 17:36 UTC  
**Topic:** Snowflake FinOps Cost Optimization (metering truth sources, billed vs consumed, idle compute)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** warehouse credit usage for the last **365 days**, including separate columns for compute credits and cloud services credits, plus an hourly measure of credits attributed to compute queries (excluding idle time). It has **up to 3h latency**, and **cloud services** in that view can lag up to **6h**.  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`.  

2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is explicitly documented as `CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES`, and it **does not include** the daily **cloud services adjustment** that affects billing; Snowflake recommends using `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` to determine how many credits were actually billed.  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY` and `METERING_DAILY_HISTORY`.  

3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits used and credits billed for the account (last **365 days**), including explicit columns for `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative) and `CREDITS_BILLED = CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES + CREDITS_ADJUSTMENT_CLOUD_SERVICES`.  
   Source: Snowflake docs for `METERING_DAILY_HISTORY`.  

4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes per-query metadata like `WAREHOUSE_NAME`, `QUERY_TAG`, `ROLE_NAME`, timing and bytes metrics, and `CREDITS_USED_CLOUD_SERVICES` (for the query’s cloud services usage). `QUERY_TAG` is present as a first-class column, which makes it a practical join key for FinOps tagging strategies (with known caveats about user adoption).  
   Source: Snowflake docs for `QUERY_HISTORY`.  

5. Resource monitors are a cost-control mechanism for **warehouses only**; they **cannot** be used to track spending for **serverless features and AI services** (Snowflake recommends using **budgets** for those categories). Resource monitor thresholds use consumption including cloud services and do **not** incorporate the daily “10% cloud services adjustment” used for billing.  
   Source: Snowflake docs for resource monitors.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes compute vs cloud services; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 3h; cloud services up to 6h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits used/billed by `SERVICE_TYPE`. Best “billed credits” truth source incl. cloud services adjustment. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query operational metadata incl. `QUERY_TAG`, `WAREHOUSE_NAME`, `ROLE_NAME`, and query cloud services credits (not billed-adjusted). |
| Resource Monitor object | Object | N/A | Controls/alerts on warehouse consumption; doesn’t cover serverless/AI services. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Consumed vs Billed” model switch in the app UI:** expose two toggles:
   - *Consumed* = sum of `WAREHOUSE_METERING_HISTORY.CREDITS_USED_*` (hourly; near-real-time)
   - *Billed* = `METERING_DAILY_HISTORY.CREDITS_BILLED` (daily; billing-adjusted)
   And clearly label that warehouse-hour data will not perfectly reconcile to billing due to adjustment logic and non-warehouse service types.

2. **Idle compute leaderboard per warehouse:** compute daily/hourly idle credits as `credits_used_compute - credits_attributed_compute_queries` and rank warehouses by avoidable idle.

3. **Guardrail recommender for monitors vs budgets:** detect whether spend is dominated by service types that resource monitors can’t control (serverless/AI services) and recommend budgets over monitors accordingly.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL: Allocate daily *billed* warehouse credits back to warehouses (proportional allocation)

This produces a **daily billed-credits estimate per warehouse** by allocating the day’s billed warehouse credits proportionally to each warehouse’s metered credits that day.

Notes:
- This is an *allocation* for chargeback/showback; it is not guaranteed to match Snowflake invoice line items for every edge case.
- Uses `SERVICE_TYPE='WAREHOUSE_METERING'` as the billed baseline.
- Assumes the daily billed credits can be allocated proportional to metered credits across warehouses.

```sql
-- Allocate billed credits for warehouse metering back to warehouses per day.
-- Requires: ACCOUNTADMIN or imported privileges to SNOWFLAKE.ACCOUNT_USAGE.

WITH wh_daily AS (
  SELECT
    TO_DATE(start_time)                           AS usage_date,
    warehouse_name,
    SUM(credits_used)                             AS credits_used_total,       -- compute + cloud services (not billing-adjusted)
    SUM(credits_used_compute)                     AS credits_used_compute,
    SUM(credits_used_cloud_services)              AS credits_used_cloud_services,
    SUM(credits_attributed_compute_queries)       AS credits_attributed_queries,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS credits_idle_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
wh_total AS (
  SELECT
    usage_date,
    SUM(credits_used_total) AS account_wh_credits_used_total
  FROM wh_daily
  GROUP BY 1
),
wh_billed AS (
  SELECT
    usage_date,
    credits_billed AS account_wh_credits_billed
  FROM snowflake.account_usage.metering_daily_history
  WHERE service_type = 'WAREHOUSE_METERING'
    AND usage_date >= DATEADD('day', -30, CURRENT_DATE())
)
SELECT
  d.usage_date,
  d.warehouse_name,
  d.credits_used_total,
  d.credits_used_compute,
  d.credits_used_cloud_services,
  d.credits_idle_compute,
  b.account_wh_credits_billed,
  t.account_wh_credits_used_total,
  IFF(t.account_wh_credits_used_total = 0,
      NULL,
      b.account_wh_credits_billed * (d.credits_used_total / t.account_wh_credits_used_total)
  ) AS allocated_billed_credits
FROM wh_daily d
JOIN wh_total t
  ON d.usage_date = t.usage_date
LEFT JOIN wh_billed b
  ON d.usage_date = b.usage_date
ORDER BY 1 DESC, allocated_billed_credits DESC;
```

### SQL: Hourly idle cost per warehouse (Snowflake doc pattern)

```sql
SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_cost,
  warehouse_name
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('days', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Allocating billed credits proportionally to metered credits assumes the cloud services adjustment can be distributed proportionally. | Chargeback numbers could differ from “true” internal billing allocation, especially if cloud services adjustments are non-linear or service-type-specific. | Compare allocated totals to `METERING_DAILY_HISTORY` by day and inspect variance; document policy. |
| `QUERY_HISTORY` doesn’t directly provide per-query warehouse compute credits; it provides metadata and some cloud services credits. | Fine-grained (per-query) compute chargeback needs other sources or approximations (e.g., query attribution views) beyond `QUERY_HISTORY` alone. | For compute attribution, validate against Snowflake’s query attribution datasets (separate research thread). |
| Resource monitors only cover warehouses. | Cost guardrails might miss serverless/AI spikes if relying on monitors alone. | Detect non-warehouse service types in `METERING_DAILY_HISTORY` and recommend budgets. |

## Links & Citations

1. Snowflake docs — `WAREHOUSE_METERING_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake docs — `METERING_DAILY_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Snowflake docs — `QUERY_HISTORY` (ACCOUNT_USAGE): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. Snowflake docs — Resource monitors (warehouses-only; budgets for serverless/AI): https://docs.snowflake.com/en/user-guide/resource-monitors

## Next Steps / Follow-ups

- Add a lightweight ADR to the app codebase: **Consumed vs Billed semantics**, with explicit reconciliation expectations.
- If we want warehouse chargeback in currency, investigate the org-level currency usage views and/or rate tables (separate research lane).
- Draft UI copy for the app explaining why hourly “consumed” and daily “billed” won’t always match exactly.
