# Research: FinOps - 2026-03-04

**Time:** 09:55 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, including `CREDITS_USED`, `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed credits, excluding idle). The view has latency up to **180 minutes**, except `CREDITS_USED_CLOUD_SERVICES` which can lag up to **6 hours**. 
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Warehouse **idle credits** are not included in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`; Snowflake’s docs provide an example to compute idle cost as `SUM(CREDITS_USED_COMPUTE) - SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)` over a time range.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides hourly credit usage at the **account** level, broken down by `SERVICE_TYPE` (warehouses + many serverless/feature/service categories). It includes `ENTITY_ID`, `ENTITY_TYPE`, and `NAME` fields whose meaning varies by `SERVICE_TYPE`.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Account Usage views differ from Information Schema by including dropped objects, having non-zero latency, and providing longer historical retention (Account Usage historical usage metrics are retained for **1 year**; Info Schema retention is shorter and varies by object). 
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage
5. Snowflake recommends avoiding `SELECT *` from Account Usage views because Snowflake-specific views are subject to change; explicitly select columns.
   - Source: https://docs.snowflake.com/en/sql-reference/account-usage

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (1y retention). Latency up to 3h; cloud services column up to 6h. Includes query-attributed compute credits + total compute credits → compute idle credit delta. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly account credits by `SERVICE_TYPE` (includes many serverless/feature/service categories). Latency up to 3h; cloud services up to 6h; Snowpipe Streaming cost can lag up to 12h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned as the way to reconcile “billed” credits vs raw credits in metering views (details not extracted in this session; verify columns/semantics). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Listed in Account Usage catalog; useful to join with metering for attribution heuristics (exact join logic remains non-trivial; see artifact). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Listed in Account Usage catalog with 8h latency; likely relevant for more direct per-query cost attribution (needs dedicated deep-dive). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle burn detector (warehouse-level)**: compute idle credits per warehouse/day (or hour) using the documented idle formula, alert when idle ratio spikes (idle/compute) or exceeds threshold.
2. **Cost “shape” dashboard**: build an hourly (or daily) “cost by service type” summary from `METERING_HISTORY` to identify big non-warehouse drivers (e.g., AUTO_CLUSTERING, SEARCH_OPTIMIZATION, SERVERLESS_TASK, SNOWPARK_CONTAINER_SERVICES, etc.).
3. **Latency-aware caching/refresh policy**: implement data freshness expectations per view/column (e.g., WAREHOUSE_METERING_HISTORY cloud services up to 6h) so the app avoids false positives for “today” anomalies.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Warehouse idle credits + idle ratio (daily)

Uses the documented relationship that query-attributed compute credits exclude idle time.

```sql
-- Warehouse idle credits and idle ratio (per day, per warehouse)
-- Sources:
-- - WAREHOUSE_METERING_HISTORY columns + latency notes
--   https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

WITH wh_hour AS (
  SELECT
    DATE_TRUNC('day', start_time) AS usage_day,
    warehouse_name,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_attributed_compute_queries) AS attributed_query_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
)
SELECT
  usage_day,
  warehouse_name,
  compute_credits,
  attributed_query_compute_credits,
  (compute_credits - attributed_query_compute_credits) AS idle_compute_credits,
  IFF(compute_credits = 0, NULL, (compute_credits - attributed_query_compute_credits) / compute_credits) AS idle_ratio
FROM wh_hour
ORDER BY usage_day DESC, idle_compute_credits DESC;
```

### SQL Draft: Hourly cost by service type (account-wide)

```sql
-- Hourly credits by service type (account-wide)
-- Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

SELECT
  start_time,
  service_type,
  entity_type,
  name,
  SUM(credits_used_compute) AS credits_used_compute,
  SUM(credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(credits_used) AS credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4
ORDER BY start_time DESC, credits_used DESC;
```

### ADR Sketch (1-page): Attribution strategy tiers

**Context:** FinOps app needs attribution that is defensible even when perfect per-query billing is not available.

**Decision:** Implement attribution in tiers with explicit confidence levels:

- **Tier 0 (Exact / documented)**
  - Warehouse idle compute credits (exact formula from Snowflake docs) using `WAREHOUSE_METERING_HISTORY`.
- **Tier 1 (High confidence)**
  - Cost by `SERVICE_TYPE` using `METERING_HISTORY` (exact service bucket totals).
- **Tier 2 (Heuristic / approximate)**
  - Allocate warehouse compute credits to dimensions like `QUERY_TAG`, `USER_NAME`, `ROLE_NAME`, `DATABASE_NAME` using `QUERY_HISTORY` time-weighting within warehouse/hour buckets (requires careful handling; label as estimated).
- **Tier 3 (If available in account)**
  - Prefer direct usage/cost views with stronger semantics (e.g., `QUERY_ATTRIBUTION_HISTORY` if it provides per-query credits) — requires deep validation.

**Why:** Users can act on Tier 0/1 immediately; Tier 2 supports chargeback/showback with transparency.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `CREDITS_USED` in metering views may not equal billed credits due to cloud services adjustments; docs point to `METERING_DAILY_HISTORY` for billed reconciliation. | Misstated spend if we treat raw credits as billed credits. | Deep-dive `METERING_DAILY_HISTORY` docs and test against billing exports in a real account. |
| Data latency (up to 6h for cloud services columns) can cause “today” anomaly false positives. | Noisy alerts / loss of trust. | Implement freshness windows; compare against prior day/hour rather than last hour for cloud services metrics. |
| Per-user/per-query attribution is not directly provided by `WAREHOUSE_METERING_HISTORY`; any “credits per user” can be heuristic without stronger source views. | Chargeback disputes. | Explore `QUERY_ATTRIBUTION_HISTORY` semantics and cross-check with Snowflake-provided examples if any. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage

## Next Steps / Follow-ups

- Deep-dive `METERING_DAILY_HISTORY` semantics (billed credits vs raw) and incorporate into the cost model.
- Research `QUERY_ATTRIBUTION_HISTORY` columns/semantics and whether it enables non-heuristic per-query credit attribution.
- Add ORG-level equivalents (`SNOWFLAKE.ORGANIZATION_USAGE.*`) for multi-account org rollups; ensure UTC session timezone alignment when reconciling views (docs mention UTC requirement for reconciliation).
