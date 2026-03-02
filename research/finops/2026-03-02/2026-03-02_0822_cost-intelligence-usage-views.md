# Research: FinOps - 2026-03-02

**Time:** 08:22 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** for warehouse-executed queries (last 365 days), but **excludes warehouse idle time** and **excludes short-running queries (<= ~100ms)**; latency can be **up to 8 hours**. [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credits** at the warehouse level for the last 365 days, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed compute credits). Idle time is not included in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. Latency is **up to 3 hours** in `ACCOUNT_USAGE`, but the `CREDITS_USED_CLOUD_SERVICES` column can lag **up to 6 hours**. [2]
3. When reconciling account-level cost views (e.g., `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`) to organization-level views (e.g., `ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY`), Snowflake recommends setting the session timezone to UTC first: `ALTER SESSION SET TIMEZONE = UTC;`. [3]
4. Snowflake’s “Exploring compute cost” guidance explicitly distinguishes between **credits consumed** (often what views show) and **credits billed** for cloud services, because cloud services usage is billed only when daily cloud services consumption exceeds **10%** of daily warehouse usage; `METERING_DAILY_HISTORY` can be used to determine what was actually billed. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits on warehouse compute; excludes idle; excludes <=~100ms queries; latency up to 8h. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Needed to enrich per-query context (user, warehouse, query tag, durations); 365d retention; latency up to ~45m per docs (varies by view list). [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes query-attributed compute credits (`CREDITS_ATTRIBUTED_COMPUTE_QUERIES`) enabling an idle-cost calculation. Latency up to 3h; cloud services column up to 6h. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to determine billed cloud services via `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (per docs). [4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` counterparts | Views | `ORG_USAGE` | Use for multi-account org-level dashboards; set session TZ to UTC for reconciliation to `ACCOUNT_USAGE`. [3] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Two-lane “Cost Attribution” model:** ship a dashboard that explicitly separates (a) per-query attributed compute (`QUERY_ATTRIBUTION_HISTORY`) and (b) warehouse-level hourly metered credits (`WAREHOUSE_METERING_HISTORY`) with computed **idle cost** (metered compute minus attributed queries). This avoids presenting per-query attribution as “total cost” when it explicitly excludes idle time. [1][2]
2. **Latency-aware freshness badges:** implement data-freshness heuristics per view (e.g., `QUERY_ATTRIBUTION_HISTORY` up to 8h, `WAREHOUSE_METERING_HISTORY` up to 3–6h) so the UI can show “data may be delayed” banners and avoid false anomaly alerts. [1][2]
3. **Org vs account reconciliation helper:** add a built-in “reconcile mode” that runs `ALTER SESSION SET TIMEZONE = UTC;` before queries and uses consistent time bucketing to align `ACCOUNT_USAGE` vs `ORGANIZATION_USAGE` results. [2][3]

## Concrete Artifacts

### SQL Draft: Warehouse Idle Cost + Query-Attributed Compute (daily)

Purpose: compute daily idle-cost credits per warehouse using `WAREHOUSE_METERING_HISTORY` and expose both metered and attributed components.

```sql
-- FinOps artifact: daily warehouse metered vs attributed compute, plus idle-cost credits.
-- Sources:
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (hourly)
-- Notes:
--   - Idle time is explicitly not included in CREDITS_ATTRIBUTED_COMPUTE_QUERIES. [2]
--   - WAREHOUSE_METERING_HISTORY credits may not reflect cloud services billed adjustments; use METERING_DAILY_HISTORY for billed cloud services. [4]

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
      DATE_TRUNC('HOUR', start_time)                               AS hour_start_utc,
      TO_DATE(CONVERT_TIMEZONE('UTC', start_time))                 AS usage_date_utc,
      warehouse_id,
      warehouse_name,
      credits_used_compute,
      credits_used_cloud_services,
      credits_used,
      credits_attributed_compute_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_id > 0  -- exclude pseudo warehouses like CLOUD_SERVICES_ONLY per Snowflake examples elsewhere
)
SELECT
    usage_date_utc,
    warehouse_name,
    SUM(credits_used_compute)                         AS credits_used_compute,
    SUM(credits_attributed_compute_queries)           AS credits_attributed_compute_queries,
    (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS credits_idle_compute,
    SUM(credits_used_cloud_services)                  AS credits_used_cloud_services,
    SUM(credits_used)                                 AS credits_used_total
FROM hourly
GROUP BY 1, 2
ORDER BY usage_date_utc DESC, credits_used_total DESC;
```

### Pseudocode: “Cost Attribution Truth Table” (UI semantics)

```text
If user asks: "cost per query"
  Use QUERY_ATTRIBUTION_HISTORY.credits_attributed_compute (+ credits_used_query_acceleration when present).
  Display warning: excludes idle time; excludes <= ~100ms queries; data latency up to 8h.

If user asks: "total warehouse cost"
  Use WAREHOUSE_METERING_HISTORY credits_used_compute (+ credits_used_cloud_services) at hourly grain.
  For "idle", compute credits_used_compute - credits_attributed_compute_queries.

If user asks: "billed cloud services"
  Use METERING_DAILY_HISTORY billed cloud services logic (credits_used_cloud_services + credits_adjustment_cloud_services).

If user asks: "org-wide"
  Prefer ORGANIZATION_USAGE views; when reconciling to ACCOUNT_USAGE, force TZ=UTC.
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `QUERY_ATTRIBUTION_HISTORY` is an authoritative “chargeback” ledger for total compute | Could mislead users because idle time is excluded and short queries are excluded | UI/Docs must state exclusions; consider combining with warehouse idle-cost computation. Validate with a known warehouse with long autosuspend. [1][2] |
| Timezone mismatches when comparing org vs account views | Off-by-one-day/hour discrepancies; false anomaly detection | Always `ALTER SESSION SET TIMEZONE = UTC` in reconciliation mode; add unit tests for time bucketing. [3] |
| Cloud services “consumed” vs “billed” confusion | Over/underestimation of billed compute in dashboards | Provide both consumed and billed metrics; use `METERING_DAILY_HISTORY` for billed cloud services. [4] |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
3. https://docs.snowflake.com/en/sql-reference/account-usage
4. https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Deepen: pull the docs for `METERING_DAILY_HISTORY` and `USAGE_IN_CURRENCY_DAILY` to design a “credits → currency” pipeline (esp. org-level). [4]
- Evaluate: how to join query-attributed compute to tags (`QUERY_TAG` and object tags) to enable cost-by-tag drilldowns; align to Snowflake’s “Viewing cost by tag in SQL” reference linked from `QUERY_ATTRIBUTION_HISTORY`. [1]
