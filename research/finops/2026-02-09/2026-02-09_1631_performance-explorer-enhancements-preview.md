# Research: FinOps - 2026-02-09

**Time:** 16:31 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake shipped **Performance Explorer enhancements** as a **Preview** feature update on **2026-02-09**.
2. The update adds investigation workflows that make it easier to attribute metric changes to recurring workloads:
   - A **“By grouped queries”** tab in side panels to identify recurring queries driving metrics.
   - **Filtering by hour**.
   - **Interactive time-window selection** by dragging over side-panel charts.
   - A **“PREVIOUS PERIOD”** column for side-panel tables to compare metrics across time.
3. Snowflake positions this feature as part of the **Performance Explorer** experience for analyzing query workloads.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Performance Explorer UI data (underlying metrics + grouped queries) | Unknown | Snowflake docs | Docs do not specify the backing views/tables in this release note. Likely driven by internal telemetry surfaced in Snowsight. Validate whether any ACCOUNT_USAGE / ORGANIZATION_USAGE views can replicate this analysis.

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **“Recurring query drivers” drilldown in the FinOps app**: replicate the new *By grouped queries* concept using query fingerprinting/grouping (e.g., normalized query text, query_hash, or parameterized signatures) to rank recurring workloads driving cost/perf regressions.
2. **Hourly slice + previous period comparison**: add an “hour-of-day” filter and default “previous period” comparisons (e.g., last 24h vs prior 24h; last 7d vs prior 7d) for key FinOps metrics (credits, queued time, spills, bytes scanned).
3. **Incident-style time-window selection**: enable users to define an investigation window (start/end) and auto-generate a packet: top warehouses, top query groups, top users/roles, and deltas vs previous period.

## Concrete Artifacts

### Feature Spec (draft): Previous-period comparison

```sql
-- Pseudocode outline (exact source views TBD):
-- 1) pick time window [t0, t1)
-- 2) compute previous window [t0-(t1-t0), t0)
-- 3) aggregate metrics for each window and join

-- NOTE: Identify the right sources:
-- - QUERY_HISTORY / WAREHOUSE_METERING_HISTORY / METERING_HISTORY
-- - potentially ORGANIZATION_USAGE views if cross-account rollups are needed
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Performance Explorer backing data is not exposed via stable SQL views | Limits ability to reproduce Snowflake UI exactly inside a Native App | Check Snowflake docs for Performance Explorer data sources; attempt to map to ACCOUNT_USAGE/ORG_USAGE views via experiments |
| Preview behavior/UI may change before GA | Features we copy too literally may drift | Track release notes until GA; implement app features as flexible “analysis patterns” rather than UI clones |

## Links & Citations

1. Snowflake release note: **“Feb 09, 2026 - Performance Explorer enhancements (Preview)”** https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview
2. Reference doc linked from release note: **Analyzing query workloads with Performance Explorer** https://docs.snowflake.com/en/user-guide/performance-explorer

## Next Steps / Follow-ups

- Pull and read the Performance Explorer user-guide page to identify any explicit references to underlying views/metrics (and whether any are accessible from SQL).
- Decide whether this belongs in the app’s **FinOps** lane (cost drivers) or **Observability** lane (performance investigation) and tag accordingly in the product backlog.
