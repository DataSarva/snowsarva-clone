# Research: FinOps - 2026-02-09
**Time:** 07:00 UTC
**Topic:** Warehouse Idle Detection & Auto-Suspend Optimization
**Researcher:** Snow (AI Assistant)
---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **WAREHOUSE_METERING_HISTORY** captures 15-second granularity for running clusters, but detecting "true idle" requires correlating with WAREHOUSE_LOAD_HISTORY and WAREHOUSE_EVENTS_HISTORY to understand query activity patterns vs. system-level operations.

2. **Auto-suspend lag** (the delay between last query completion and warehouse suspension) is configurable per warehouse (1-600 minutes), but most accounts use defaults that waste credits on idle-but-running warehouses.

3. **Idle time cost** scales linearly with warehouse size: a Medium warehouse running idle for 1 hour = ~0.67 credits/hour (~$40/1000hrs at $2/credit). At scale (100s of warehouses), this becomes significant.

4. **Detection signals available:**
   - `WAREHOUSE_LOAD_HISTORY`: average_running, average_queued, average_blocked per 15s
   - `WAREHOUSE_METERING_HISTORY`: credits used per 15s
   - `WAREHOUSE_EVENTS_HISTORY`: START/RESUME/SUSPEND events with timestamps
   - Current sessions via `SHOW SESSIONS` or `SNOWFLAKE.ACCOUNT_USAGE.SESSIONS`

5. **Recommended auto-suspend threshold depends on workload pattern:**
   - Continuous low-volume queries → 5+ minutes (avoid thrashing)
   - Batch/reporting workloads → 1-2 minutes (aggressive suspend)
   - ETL pipelines → Keep un-suspended with explicit management

6. **Snowflake does not expose** a "true idle" flag — we must infer from LOAD_HISTORY showing zero active queries but non-zero provisioning/running capacity.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | History | ACCOUNT_USAGE | 15s granularity, includes credits per cluster |
| WAREHOUSE_LOAD_HISTORY | History | ACCOUNT_USAGE | avg_running, avg_queued, avg_blocked, avg_provisioning per 15s |
| WAREHOUSE_EVENTS_HISTORY | Events | ACCOUNT_USAGE | START, RESUME, SUSPEND, BROADCAST events |
| WAREHOUSES | Metadata | SHOW | Current auto-suspend settings, size, status |
| SESSIONS | View | ACCOUNT_USAGE | Active session info (delayed ~2hr) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked

1. **Idle Detection Dashboard** — Continuous monitoring showing warehouses with >X minutes of zero query activity but running state, with estimated daily wasted credits.

2. **Auto-Suspend Recommendation Engine** — Analyze historical patterns per warehouse, recommend optimal auto-suspend thresholds (1min, 2min, 5min, etc.) with projected savings calculations.

3. **Stop/Start Automation Controls** — Stored procedures that power "intelligent suspend" buttons in Native App UI, reducing provider-side idle cost exposure.

---

## Concrete Artifacts

### Artifact 1: SQL Schema — Idle Detection Fact Tables
See: `/home/ubuntu/.openclaw/workspace/sql/warehouse_idle_detection_draft.sql`

### Artifact 2: ADR — Warehouse Idle Detection Architecture
See: `/home/ubuntu/.openclaw/workspace/docs/ADR_0003_warehouse_idle_detection.md`

### Artifact 3: Python Snowpark — Idle Detection Analysis Module
See: `/home/ubuntu/.openclaw/workspace/python/snowpark/idle_detection.py`

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| WAREHOUSE_LOAD_HISTORY has up to 35-minute latency | Near-real-time idle detection impossible | Test latency in consumer environment; document acceptable staleness |
| Auto-suspend settings require MODIFY privilege on warehouse | App cannot change settings without appropriate grants | Document required privileges, add "recommendation only" mode |
| Query-less intervals may still have background processes (e.g., streaming) | False-positive idle detection | Correlate with PIPE usage, STREAM status in detection logic |
| Multi-cluster warehouses behave differently (scaling event timing) | Incorrect idle time calculation for scaled clusters | Test against multi-cluster configurations, adjust algorithm |
| Credits wasted calculation assumes sustained idle at full rate | May overestimate if warehouse auto-suspended mid-hour | Refine to use actual metering history per-15s |

---

## Links & Citations

1. Snowflake Docs: WAREHOUSE_METERING_HISTORY — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake Docs: WAREHOUSE_LOAD_HISTORY — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_load_history
3. Snowflake Docs: Warehouse Load Monitoring — https://docs.snowflake.com/en/user-guide/warehouse-load
4. Snowflake Docs: AUTO_SUSPEND parameter — https://docs.snowflake.com/en/sql-reference/parameters.html#auto-suspend
5. Snowflake Docs: ALTER WAREHOUSE — https://docs.snowflake.com/en/sql-reference/sql/alter-warehouse

---

## Next Steps / Follow-ups

1. [ ] Validate latency assumptions in live ACCOUNT_USAGE environment — measure actual load history delay
2. [ ] Add STREAM/PIPE correlation to idle detection to reduce false positives
3. [ ] Extend to ORG_USAGE views for multi-account organization-wide idle detection
4. [ ] Build Streamlit visuals in Native App for idle warehouse timeline visualization
5. [ ] Add cost projection: model what credits would be saved with recommended thresholds vs. current
