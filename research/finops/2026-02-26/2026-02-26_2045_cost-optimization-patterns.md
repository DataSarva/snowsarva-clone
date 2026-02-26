# Research: FinOps - 2026-02-26

**Time:** 20:45 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake virtual warehouses are billed per-second, but with a **60-second minimum** each time a warehouse is started/resumed (and also when resizing to a larger size). Suspending/resuming within the first minute can incur multiple 60-second minimum charges. (Understanding compute cost) https://docs.snowflake.com/en/user-guide/cost-understanding-compute
2. Warehouse sizing approximately **doubles credits/hour** at each size step; however, “larger is not necessarily faster for small, basic queries,” so right-sizing must be workload-driven rather than defaulting to “bigger.” (Warehouse overview) https://docs.snowflake.com/en/user-guide/warehouses-overview
3. Auto-suspend is a foundational cost control: by default it is enabled for warehouses; it prevents idle-time credit burn by suspending after inactivity, while auto-resume starts the warehouse when needed. (Warehouse overview) https://docs.snowflake.com/en/user-guide/warehouses-overview
4. The `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view provides **hourly credits** by warehouse (last 365 days) and includes both compute credits and cloud services credits; it also includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which can be used to estimate **idle cost** (compute credits not attributed to query execution). (WAREHOUSE_METERING_HISTORY) https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
5. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is the sum of compute + cloud services credits and **does not include** the “cloud services 10% adjustment,” so it can be higher than billed credits; reconciling billed amounts requires other metering views (e.g., `METERING_DAILY_HISTORY`). (WAREHOUSE_METERING_HISTORY; Exploring compute cost) https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history and https://docs.snowflake.com/en/user-guide/cost-exploring-compute
6. Snowflake’s Well-Architected “Cost Optimization & FinOps” guidance frames cost work into **Visibility → Control → Optimize**, emphasizing: cost-aware design constraints, consistent cost attribution (tags + query tags), and automated guardrails (resource monitors, timeouts, budgets). (Well-Architected Cost Optimization) https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly warehouse credits. Includes compute vs cloud services vs query-attributed compute credits; useful for idle-cost estimation. Latency up to 180 min (compute) / up to 6 hours (cloud services). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Used to determine how many credits were actually billed for compute after cloud-services adjustment. (Mentioned in Exploring compute cost.) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits for warehouses/cloud services/serverless features. (Mentioned in Exploring compute cost.) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Needed for query-level drivers + attribution (e.g., query tags) as recommended by Well-Architected. (Referenced in Well-Architected + Exploring compute cost.) |
| Snowsight Admin → Cost Management (Consumption/Anomalies) | UI | Snowsight | Snowflake recommends using an XS warehouse to view usage data in UI. (Exploring compute cost.) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Idle credit burn report (warehouse-level):** daily/weekly “idle-cost” leaderboard per warehouse (and trend over time) using `WAREHOUSE_METERING_HISTORY` compute vs query-attributed compute.
2. **Cost driver drill-down:** split warehouse credits into **compute vs cloud services** and flag “high cloud services ratio” warehouses for follow-up; link to “top query types/users” for that warehouse using `QUERY_HISTORY` (per Snowflake’s compute cost exploration patterns).
3. **Guardrail posture check:** “FinOps Controls Scorecard” that detects risky warehouse configs (e.g., auto-suspend disabled or too high, long statement timeouts) and recommends guardrails aligned to Well-Architected “Control” guidance (resource monitors, timeouts, etc.).

## Concrete Artifacts

### SQL Draft: Warehouse idle-cost + cloud-services ratio (last 30 days)

```sql
-- Warehouse idle cost is compute credits not attributed to query execution.
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- (See idle-cost example in the docs.)

WITH wh_30d AS (
  SELECT
    warehouse_name,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_services_credits,
    SUM(credits_attributed_compute_queries) AS attributed_query_compute_credits,
    SUM(credits_used) AS total_pre_adjustment_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND warehouse_id > 0 -- skip pseudo VWs, aligns with examples in Exploring compute cost
  GROUP BY 1
)
SELECT
  warehouse_name,
  compute_credits,
  cloud_services_credits,
  (compute_credits - attributed_query_compute_credits) AS idle_compute_credits_est,
  IFF(compute_credits = 0, NULL, (compute_credits - attributed_query_compute_credits) / compute_credits) AS idle_compute_pct_est,
  IFF(total_pre_adjustment_credits = 0, NULL, cloud_services_credits / total_pre_adjustment_credits) AS cloud_services_ratio_pre_adjustment,
  total_pre_adjustment_credits
FROM wh_30d
ORDER BY total_pre_adjustment_credits DESC;
```

### ADR Sketch (one-page): Use `WAREHOUSE_METERING_HISTORY` as the “compute spine” for early FinOps MVP

**Status:** Draft  
**Decision:** For early FinOps MVP, define “compute cost analytics” around `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` as the primary fact table, with optional enrichment from `QUERY_HISTORY`.

**Why:**
- The view is canonical Snowflake telemetry for hourly warehouse credits, includes compute vs cloud services credits, and supports an idle-cost estimate via `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- It directly supports multiple cost-optimization patterns recommended by Snowflake (visibility + drill-down), while keeping queries relatively simple. https://docs.snowflake.com/en/user-guide/cost-exploring-compute

**Consequences / follow-ups:**
- Values are “pre cloud-services adjustment” and may differ from billed; to reconcile with billing, integrate `METERING_DAILY_HISTORY` in a later iteration. https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Assuming `CREDITS_USED` in `WAREHOUSE_METERING_HISTORY` reflects billed credits. | Overstates true billed amounts when cloud-services adjustment applies. | Add reconciliation path via `METERING_DAILY_HISTORY` (docs explicitly recommend this). https://docs.snowflake.com/en/user-guide/cost-exploring-compute |
| Assuming low auto-suspend is always best. | Too aggressive auto-suspend can cause extra 60s minimum charges or user latency due to frequent resumes; “best” is workload-dependent. | Validate against workload patterns + per-second billing with 60s minimum. https://docs.snowflake.com/en/user-guide/cost-understanding-compute |
| Warehouse history latency (up to ~3 hours; cloud services up to 6 hours). | Near-real-time dashboards can be misleading. | Design UI to label “data freshness” and/or use alternative (INFO_SCHEMA) for faster signals if applicable. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history |

## Links & Citations

1. Snowflake Well-Architected Framework: Cost Optimization & FinOps (principles + recommendations) — https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
2. Snowflake Docs: Understanding compute cost (per-second billing + 60s min; cloud services 10% adjustment) — https://docs.snowflake.com/en/user-guide/cost-understanding-compute
3. Snowflake Docs: Overview of warehouses (warehouse sizes; auto-suspend/auto-resume basics) — https://docs.snowflake.com/en/user-guide/warehouses-overview
4. Snowflake Docs: `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (columns, latency, idle-cost example) — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
5. Snowflake Docs: Exploring compute cost (how to drill into cost; recommends `METERING_DAILY_HISTORY` for billed; example queries) — https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Add a second note focused specifically on **cost attribution**: query tags, object tags, and how to allocate idle time fairly across tenants/cost centers.
- Expand artifacts into a canonical “FinOps compute mart” schema (fact tables + dims) suitable for a Native App dashboard.
- Validate which views are accessible/allowed in the Snowflake Native App runtime context (e.g., which `ACCOUNT_USAGE` objects are permitted) and document any required grants.
