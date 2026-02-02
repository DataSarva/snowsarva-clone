# FinOps Research Note — ACCOUNT_USAGE cost telemetry foundation for a FinOps Native App

- **When (UTC):** 2026-02-02 03:11
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs a stable, low-friction “telemetry substrate” for spend + drivers (warehouses, queries, storage) that works across customer accounts, supports least-privilege RBAC, and yields consistent KPIs (credits/day, cost/unit, top drivers) for recommendations.

## Accurate takeaways
- Snowflake provides a first-class set of **ACCOUNT_USAGE** views in the **SNOWFLAKE** database intended for account-level governance/monitoring, and these are the canonical starting point for usage + cost analytics in a customer account. [Snowflake Account Usage docs](https://docs.snowflake.com/en/sql-reference/account-usage)
- Credit consumption at the warehouse layer can be sourced from **ACCOUNT_USAGE.METERING_HISTORY** (warehouse-level credits by time window), which is directly useful for: (a) daily/weekly spend trend, (b) warehouse right-sizing candidates, and (c) cost allocation by warehouse as a proxy when query attribution is partial. [METERING_HISTORY view](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history)
- Query-level telemetry can be sourced from **ACCOUNT_USAGE.QUERY_HISTORY** for “top cost drivers” analysis (high elapsed time, high bytes scanned, frequent execution), which drives recommendations like clustering/partitioning, caching, materialization, or warehouse tuning. [QUERY_HISTORY view](https://docs.snowflake.com/en/sql-reference/account-usage/query_history)
- Snowflake’s own guidance positions FinOps as a combination of: baselining using Account Usage views, tying consumption to business value, and continuously detecting outliers / opportunities. [Cost Optimization & FinOps (Well-Architected Framework)](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/)
- For an MVP, **Snowsight-style “overall cost exploration”** concepts translate cleanly into a Native App UI: time-series of credits, breakdown by warehouse/service, and drilldowns for “what changed” in the last N days. [Exploring overall cost](https://docs.snowflake.com/en/user-guide/cost-exploring-overall)

## Snowflake objects & data sources (verify in target account)
**Core (ACCOUNT_USAGE / SNOWFLAKE DB):**
- `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` — warehouse metering (credits) by time.
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` — query execution history.
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES` — warehouse definitions (size, auto-suspend, etc.) (not extracted in this run; expected to exist under Account Usage).
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` — alternative/companion warehouse metering view (validate which is better for aggregation and lag; not extracted in this run).
- `SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY` / `...STAGE_STORAGE_USAGE_HISTORY` / `...TABLE_STORAGE_METRICS` — storage drivers (validate which set is available/needed).

**Notes / verification needed:**
- Data latency/retention differs by view; the app should surface “freshness” and avoid implying real-time billing.
- Some org-level rollups may require ORG_USAGE (not covered in this note).

## MVP features unlocked (PR-sized)
1) **“Credits & drivers” daily dashboard** (time series + breakdown): credits/day, top warehouses/day, top queries/day.
2) **Warehouse spend leaderboard + right-sizing hints**: identify warehouses with high credits and low query concurrency; flag auto-suspend / size changes.
3) **Top query cost drivers**: show top queries by total execution time and bytes scanned; tag the owning warehouse + user/role.

## Heuristics / detection logic (v1)
- **Spend spike detection**: compare last 24h credits vs trailing 7-day baseline per warehouse; alert when >Xσ or >Y% increase.
- **Idle burn**: warehouses with credits but low query counts (metering history non-zero while query history shows low activity) → investigate auto-suspend, serverless features, or background tasks.
- **Inefficient heavy scanners**: queries with high bytes scanned and low row return (or long time) → recommend pruning / clustering / search optimization / materialized views (recommendation depends on object types).

## Concrete artifact — SQL draft (v0)
> Goal: Provide a minimal, portable set of SQL the Native App can run (with required privileges) to generate dashboards.

### A) Daily warehouse credits (last 30 days)
```sql
-- Daily credits by warehouse
SELECT
  DATE_TRUNC('DAY', START_TIME) AS day,
  WAREHOUSE_NAME,
  SUM(CREDITS_USED) AS credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY day DESC, credits_used DESC;
```

### B) Daily query counts + total elapsed time by warehouse (last 30 days)
```sql
SELECT
  DATE_TRUNC('DAY', START_TIME) AS day,
  WAREHOUSE_NAME,
  COUNT(*) AS query_count,
  SUM(TOTAL_ELAPSED_TIME) / 1000.0 AS total_elapsed_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1, 2
ORDER BY day DESC, total_elapsed_seconds DESC;
```

### C) “Top drivers” queries (last 7 days)
```sql
SELECT
  QUERY_ID,
  START_TIME,
  USER_NAME,
  ROLE_NAME,
  WAREHOUSE_NAME,
  TOTAL_ELAPSED_TIME/1000.0 AS elapsed_seconds,
  BYTES_SCANNED,
  BYTES_WRITTEN,
  ROWS_PRODUCED,
  QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 100;
```

## Security/RBAC notes
- The Native App will need **read access** to the relevant `SNOWFLAKE.ACCOUNT_USAGE` views. Exact grants and feasibility depend on Snowflake’s Native App privilege model in the consumer account.
- Design suggestion: implement a **“Telemetry Reader” application role** and provide a setup worksheet that guides the customer admin to grant the minimum required privileges (e.g., USAGE on `SNOWFLAKE` db/schema and SELECT on specific views). Validate whether additional privileges (e.g., `MONITOR USAGE`) are required in practice.

## Risks / assumptions
- **Schema/columns** in ACCOUNT_USAGE views can evolve; our SQL must be defensive (explicit column lists, avoid `SELECT *`, tolerate NULL warehouses).
- **Attribution gap**: warehouse credits are not always cleanly attributable to specific queries (concurrency, caching, background services). Any “query cost” scoring should be labeled as heuristic unless Snowflake provides direct per-query credit attribution in available views.
- **Latency**: ACCOUNT_USAGE is not always real-time; recommendations should show the data window and freshness.

## Links / references
- https://docs.snowflake.com/en/sql-reference/account-usage
- https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
- https://docs.snowflake.com/en/sql-reference/account-usage/query_history
- https://docs.snowflake.com/en/user-guide/cost-exploring-overall
- https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
