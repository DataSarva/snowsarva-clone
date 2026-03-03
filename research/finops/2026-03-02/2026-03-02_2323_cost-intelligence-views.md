# Research: FinOps - 2026-03-02

**Time:** 2323 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for the last **365 days**, including separate compute vs cloud-services credits, plus `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (credits attributed to query execution only). The attributed value excludes warehouse idle time. (Citation: WAREHOUSE_METERING_HISTORY)
2. Data in `ACCOUNT_USAGE` can have non-trivial **latency**: up to **180 minutes** generally for `WAREHOUSE_METERING_HISTORY` (and up to **6 hours** for `CREDITS_USED_CLOUD_SERVICES`). This means “near-real-time cost dashboards” should either tolerate staleness or use alternative sources. (Citation: WAREHOUSE_METERING_HISTORY)
3. `CREDITS_USED` and `credits_used_cloud_services` values in account usage views may be **greater than billed credits** because they do not account for Snowflake’s “cloud services adjustment”; Snowflake points to `METERING_DAILY_HISTORY` to determine billed credits. (Citations: WAREHOUSE_METERING_HISTORY, QUERY_HISTORY)
4. When reconciling `ACCOUNT_USAGE` with `ORGANIZATION_USAGE`, Snowflake instructs setting the session timezone to **UTC** before querying the account usage view. (Citation: WAREHOUSE_METERING_HISTORY)
5. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` contains query-level metadata including `warehouse_name`, `query_tag`, elapsed times, bytes scanned, and `credits_used_cloud_services`. These fields enable “who/what/where” attribution dimensions, but **not** direct warehouse compute credits per query from this view alone. (Citation: QUERY_HISTORY)
6. `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` exposes monitor quotas and thresholds (notify/suspend/suspend_immediate) plus current cycle used/remaining credits, enabling “budget guardrail” UX. (Citation: RESOURCE_MONITORS)
7. `SNOWFLAKE.ORGANIZATION_USAGE` provides historical usage data across accounts in an org (via `SNOWFLAKE` shared database), but many views are marked as **premium** and/or have **24h latency**. (Citation: Organization Usage)
8. Warehouse size correlates with credit consumption (e.g., Gen1 X-Small = 1 credit/hour; doubling each size), and billing is **per-second** with a **60-second minimum** each time a warehouse starts. This underpins optimization heuristics like aggressive auto-suspend and consolidation/batching. (Citation: Warehouses Overview)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (compute + cloud services); `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` excludes idle time; latency up to 3h (cloud services up to 6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level dimensions (user/role/warehouse/query_tag, bytes scanned, timings) and `credits_used_cloud_services` (not billed-adjusted). |
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | `ACCOUNT_USAGE` | Quota + used/remaining credits and thresholds; can power budgets/alerts UI. |
| `SNOWFLAKE.ORGANIZATION_USAGE`.* | Schema | `ORG_USAGE` | Cross-account usage; many views 24h latency and/or premium. Good for multi-account rollups when available. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned by Snowflake docs as the place to determine billed credits (vs “used” values). **Not deep-read in this session** (follow-up). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle-cost leaderboard** per warehouse (last N days) using `WAREHOUSE_METERING_HISTORY` formula: `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`. Add breakdown by day and a “top offenders” panel.
2. **Staleness-aware cost tiles**: show `data_freshness_minutes` (based on max `END_TIME`) with UX cues + configurable “freshness SLO” (because metering has up to ~3–6h latency).
3. **Budget guardrails UI** driven by `RESOURCE_MONITORS`: list monitors, quota, used, remaining, thresholds; highlight warehouses attached; link to actions (create/modify monitor) as guided SQL.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: Core SQL model for compute+idle cost per warehouse + staleness

```sql
-- Purpose:
--   Produce a warehouse-level FinOps fact set:
--   - compute credits used
--   - compute credits attributed to queries
--   - derived idle credits
--   - cloud services credits (used, not billed-adjusted)
--   - freshness indicators
--
-- Sources:
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--   - In ACCOUNT_USAGE, data can be up to 180 min stale (cloud services up to 6h).
--   - For reconciliation vs ORG_USAGE, Snowflake recommends setting TIMEZONE=UTC.

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
      START_TIME,
      END_TIME,
      WAREHOUSE_NAME,
      CREDITS_USED_COMPUTE,
      CREDITS_ATTRIBUTED_COMPUTE_QUERIES,
      (CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES) AS CREDITS_IDLE_COMPUTE,
      CREDITS_USED_CLOUD_SERVICES
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP())
), agg AS (
  SELECT
      DATE_TRUNC('day', START_TIME) AS DAY,
      WAREHOUSE_NAME,
      SUM(CREDITS_USED_COMPUTE) AS COMPUTE_CREDITS_USED,
      SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES) AS COMPUTE_CREDITS_ATTRIBUTED_TO_QUERIES,
      SUM(CREDITS_IDLE_COMPUTE) AS COMPUTE_CREDITS_IDLE,
      SUM(CREDITS_USED_CLOUD_SERVICES) AS CLOUD_SERVICES_CREDITS_USED,
      MAX(END_TIME) AS MAX_END_TIME
  FROM hourly
  GROUP BY 1, 2
)
SELECT
    DAY,
    WAREHOUSE_NAME,
    COMPUTE_CREDITS_USED,
    COMPUTE_CREDITS_ATTRIBUTED_TO_QUERIES,
    COMPUTE_CREDITS_IDLE,
    CLOUD_SERVICES_CREDITS_USED,
    DATEDIFF('minute', MAX_END_TIME, CURRENT_TIMESTAMP()) AS DATA_STALENESS_MINUTES
FROM agg
ORDER BY DAY DESC, COMPUTE_CREDITS_USED DESC;
```

### Artifact: Query dimensions you can join for “who/what” (no compute credits yet)

```sql
-- Purpose:
--   Pull query-level dimensions for attribution slices (user, role, query_tag, bytes_scanned, timings).
--   NOTE: This view includes credits_used_cloud_services but not warehouse compute credits per query.

SELECT
  QUERY_ID,
  START_TIME,
  END_TIME,
  USER_NAME,
  ROLE_NAME,
  WAREHOUSE_NAME,
  QUERY_TAG,
  QUERY_TYPE,
  EXECUTION_STATUS,
  BYTES_SCANNED,
  TOTAL_ELAPSED_TIME,
  EXECUTION_TIME,
  CREDITS_USED_CLOUD_SERVICES
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Used credits” in `ACCOUNT_USAGE` are not necessarily “billed credits” due to cloud services adjustment. | Incorrect $ attribution if app equates used credits to billed spend. | Add a follow-up deep read and implement billed-cost pathway via `METERING_DAILY_HISTORY` (and org equivalents when available). |
| `ACCOUNT_USAGE` metering latency (3–6h) may disappoint users expecting near-real-time cost charts. | UX complaints / false alarms. | Ship explicit freshness indicators and “last updated” hints; optionally support user-configured backfill windows. |
| ORG rollups may require premium org views (and 24h latency). | Multi-account features may not work in all customers. | Detect availability/privileges at install time; feature-flag org mode. |
| Compute cost attribution to *queries* is incomplete without additional attribution views or logic. | Per-team/query costing may be misleading. | Investigate `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` and/or account-level attribution equivalents as a follow-up. |

## Links & Citations

1. Snowflake Docs — `WAREHOUSE_METERING_HISTORY` (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Docs — `QUERY_HISTORY` (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. Snowflake Docs — `RESOURCE_MONITORS` (Account Usage): https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors
4. Snowflake Docs — Organization Usage overview: https://docs.snowflake.com/en/sql-reference/organization-usage
5. Snowflake Docs — Warehouses overview (size + per-second billing details): https://docs.snowflake.com/en/user-guide/warehouses-overview

## Next Steps / Follow-ups

- Deep read `METERING_DAILY_HISTORY` (account + org) to formalize “billed credits” vs “used credits” in the app’s semantic model.
- Research query-level compute attribution paths (e.g., org `QUERY_ATTRIBUTION_HISTORY`) and decide whether per-query $$ is MVP or v2.
- Draft a small “Cost Semantic Model” ADR: sources, latencies, reconciliation strategy, and recommended default windows.
