# Research: FinOps - 2026-02-27

**Time:** 01:02 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for up to **365 days**, and `CREDITS_USED` is the sum of compute + cloud services credits **without** applying the daily cloud-services billing adjustment; Snowflake directs you to use `METERING_DAILY_HISTORY` to determine what was actually billed.  
   Source: Snowflake docs for `WAREHOUSE_METERING_HISTORY`.
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits used, a `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (negative) and `CREDITS_BILLED` (= compute + cloud services + adjustment) for up to **365 days**; it is the canonical place to compute what was billed for cloud services after the “10% of warehouse usage” rule is applied.  
   Source: Snowflake docs for `METERING_DAILY_HISTORY` + “Understanding overall cost”.
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes (among many other fields) `QUERY_TAG`, `WAREHOUSE_NAME`, and `CREDITS_USED_CLOUD_SERVICES` for each query, but the per-query cloud services credits **do not** reflect the daily billing adjustment; Snowflake again points to `METERING_DAILY_HISTORY` for billed amounts.  
   Source: Snowflake docs for `QUERY_HISTORY`.
4. Snowflake’s `SNOWFLAKE.ORGANIZATION_USAGE` schema provides historical usage views across all accounts in an org, with **latency and retention** varying per view; it includes a `METERING_DAILY_HISTORY` view at the org level with stated latency (listed as **2 hours** on the schema overview page).  
   Source: Snowflake docs for `ORGANIZATION_USAGE` schema overview.
5. When reconciling `ACCOUNT_USAGE` views with corresponding org-level usage views, Snowflake notes you should set the session timezone to UTC (`ALTER SESSION SET TIMEZONE = UTC`) before querying the account usage view(s).  
   Source: usage notes in `WAREHOUSE_METERING_HISTORY` and `METERING_DAILY_HISTORY`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (`CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_USED`), with `CREDITS_USED` not adjusted for billing; up to 6h latency for cloud services column. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits by `SERVICE_TYPE`; includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata including `QUERY_TAG`, `WAREHOUSE_NAME`, and `CREDITS_USED_CLOUD_SERVICES` (not billed-adjusted). |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Org-wide equivalent of metering daily history (schema overview lists it; per-view details not pulled in this session). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Billed credits “source of truth” module**: standardize all app “cost totals” on `ACCOUNT_USAGE.METERING_DAILY_HISTORY.CREDITS_BILLED` and expose breakdown by `SERVICE_TYPE` (warehouse vs serverless features). This prevents double-counting cloud services that later get adjusted.
2. **Idle cost leaderboard**: for each warehouse, compute idle credits for the last N days using `WAREHOUSE_METERING_HISTORY` (`credits_used_compute - credits_attributed_compute_queries`) and surface “top idle burners”; this is explicitly suggested in Snowflake’s example.
3. **Query-tag hygiene & allocation**: use `QUERY_HISTORY.QUERY_TAG` + `WAREHOUSE_NAME` to report “who ran what” and create a best-effort allocation of warehouse hourly compute to tags/users (acknowledging Snowflake does not expose exact per-query warehouse compute credits in these views).

## Concrete Artifacts

### 1) SQL draft — Daily billed credits (canonical) + cloud services billed amount

```sql
-- Canonical billed credits per day and service type.
-- Source of truth for what was actually billed (includes cloud-services adjustment).
--
-- Notes:
-- - View latency may be up to 180 minutes.
-- - If reconciling with ORG_USAGE equivalents, set session timezone to UTC.

ALTER SESSION SET TIMEZONE = UTC;

WITH base AS (
  SELECT
    usage_date,
    service_type,
    credits_used_compute,
    credits_used_cloud_services,
    credits_adjustment_cloud_services,
    credits_billed
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
)
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed,
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS cloud_services_billed
FROM base
ORDER BY usage_date DESC, credits_billed DESC;
```

### 2) SQL draft — Warehouse idle credits (compute-only) for last 10 days

```sql
-- From Snowflake docs example, included here because it’s a clean MVP.
-- Computes compute idle credits (does not include cloud-services).

SELECT
  (SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)) AS idle_compute_credits,
  warehouse_name
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -10, CURRENT_DATE())
  AND end_time < CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY idle_compute_credits DESC;
```

### 3) Pseudocode — Best-effort allocation of hourly warehouse compute credits to query tags

Snowflake exposes hourly warehouse compute credits and per-query metadata (including `QUERY_TAG`), but **does not** expose exact “compute credits used by query” in these views. A pragmatic FinOps approach is to allocate hourly compute credits proportionally to query execution time (or another proxy) within the same warehouse-hour window.

```text
for each hour H and warehouse W:
  total_hour_compute_credits = WAREHOUSE_METERING_HISTORY.credits_used_compute where W,W and start_time=H
  queries = QUERY_HISTORY where warehouse_name=W and start_time in [H, H+1)
  weight(query) = max(query.execution_time_ms, 1)  # proxy
  allocate(query) = total_hour_compute_credits * weight(query)/sum(weights)

roll up allocations by query_tag / user / role / database / schema
```

If we implement this, we should label results as **allocation (estimated)** and provide toggles for different weight functions (elapsed, execution, bytes_scanned) depending on workload type.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Hourly warehouse credits can be meaningfully allocated to queries using time-based proxies. | Might misattribute cost for concurrency-heavy workloads and for idle time. | Compare allocation totals to hourly `credits_attributed_compute_queries` and present idle separately; test on a few warehouses with known patterns. |
| `METERING_DAILY_HISTORY` is the correct “billed credits” source for all in-app totals. | If there are org-level nuances or contract constructs, totals might differ from invoices. | Cross-check against Snowsight billing/usage UI and (if available) ORG_USAGE contract/rate sheet views. |
| ORG_USAGE `METERING_DAILY_HISTORY` exists and can be used for cross-account dashboards. | Requires org account access; some views are premium / org-only. | Confirm availability in target customer accounts and document prerequisite roles/privileges. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4. https://docs.snowflake.com/en/sql-reference/organization-usage
5. https://docs.snowflake.com/en/user-guide/cost-understanding-overall

## Next Steps / Follow-ups

- Pull the dedicated docs pages for `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` and `QUERY_ATTRIBUTION_HISTORY` (listed in the schema overview) and confirm column-level compatibility/latency/retention.
- Decide the app’s “cost truth hierarchy”: `ACCOUNT_USAGE` (single account) vs `ORGANIZATION_USAGE` (org rollups) and how we handle mixed availability.
- Prototype the estimated allocation model behind a feature flag with strong disclaimers + validation dashboard (allocated vs metering totals).
