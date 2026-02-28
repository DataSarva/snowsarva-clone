# Research: FinOps - 2026-02-28

**Time:** 1316 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides per-query warehouse compute credits (`CREDITS_ATTRIBUTED_COMPUTE`) for queries run on warehouses in the last **365 days**, with **up to ~8 hours latency**. It **excludes warehouse idle time** and currently **excludes short-running queries (<= ~100ms)**.  
   Source: Snowflake docs (QUERY_ATTRIBUTION_HISTORY usage notes).
2. Query-attributed compute cost **does not include** other costs incurred as a result of query execution (e.g., **cloud services**, **serverless feature costs**, **storage**, **data transfer**, **AI token costs**).  
   Source: Snowflake docs (Attributing cost + QUERY_ATTRIBUTION_HISTORY).
3. There is **no ORGANIZATION_USAGE equivalent** of `QUERY_ATTRIBUTION_HISTORY`; org-wide attribution must roll up differently (e.g., warehouse/tag-based, org metering, etc.).  
   Source: Snowflake docs (Attributing cost).
4. Snowflake recommends a tagging-based chargeback/showback strategy using:  
   - **object tags** (warehouses, users) for ownership and stable cost centers; and  
   - **query tags** for shared apps/workflows that issue queries on behalf of multiple groups.  
   Source: Snowflake docs (Attributing cost).
5. If you want to reconcile to “what you were actually billed”, Snowflake notes that cloud services credits are only billed if daily cloud services consumption exceeds **10%** of daily warehouse consumption; `METERING_DAILY_HISTORY` can be used to determine billed cloud services.  
   Source: Snowflake docs (Exploring compute cost).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query warehouse compute credits; excludes idle time; latency up to ~8h; <=~100ms queries excluded. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes cloud services cost associated with using the warehouse (per docs). |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Maps tagged objects (domain/object_id/object_name) to tag name/value. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORGANIZATION_USAGE` | Daily credits + currency conversion using daily credit price (org-wide). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits used + cloud services adjustment; can help derive billed cloud services per docs. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Used to map stored procedures to root query ids for hierarchical rollups (paired with query attribution). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Chargeback by tag with reconciliation**: Provide “Attributed credits” dashboards that (a) compute costs from `QUERY_ATTRIBUTION_HISTORY` for tagged workloads and (b) optionally **allocates idle time** back across tags proportionally so the totals reconcile to `WAREHOUSE_METERING_HISTORY` (warehouse billed compute) for a period.
2. **Top recurrent queries by cost center**: Use `query_parameterized_hash` rollups from `QUERY_ATTRIBUTION_HISTORY` to identify expensive recurring query families; slice by `QUERY_TAG` and/or user tag mappings.
3. **Data freshness + correctness guardrails**: Because `QUERY_ATTRIBUTION_HISTORY` can lag up to ~8 hours and excludes <=~100ms queries, expose a “completeness watermark” in the app and flag “likely undercount” windows.

## Concrete Artifacts

### SQL: workload (query_tag) attribution with optional idle-time reconciliation

Goal: return per-`QUERY_TAG` credits for the last N days in two modes:
- `mode = 'attributed_only'` (pure `QUERY_ATTRIBUTION_HISTORY`, excludes idle)
- `mode = 'reconciled_with_idle'` (allocates idle proportionally so totals reconcile to `WAREHOUSE_METERING_HISTORY` for the same period)

```sql
-- PARAMETERS
SET days_back = 30;

WITH
-- 1) Metered warehouse compute credits for the period
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -$days_back, CURRENT_TIMESTAMP())
    AND start_time <  CURRENT_TIMESTAMP()
),

-- 2) Query-attributed credits by query_tag for the period (idle excluded by definition)
qah_by_tag AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS attributed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('day', -$days_back, CURRENT_TIMESTAMP())
    AND start_time <  CURRENT_TIMESTAMP()
  GROUP BY 1
),

-- 3) Total query-attributed credits in period (denominator for proportional allocation)
qah_total AS (
  SELECT SUM(attributed_credits) AS sum_all_attributed
  FROM qah_by_tag
),

-- 4) Reconciled credits: distribute warehouse idle (and any non-attributed gaps) proportionally
reconciled AS (
  SELECT
    t.tag,
    /*
      If you want reconciliation: scale tags up to match warehouse compute credits.
      This matches Snowflake's pattern shown in cost attribution docs.
    */
    CASE
      WHEN q.sum_all_attributed = 0 THEN 0
      ELSE (t.attributed_credits / q.sum_all_attributed) * w.compute_credits
    END AS reconciled_credits
  FROM qah_by_tag t
  CROSS JOIN qah_total q
  CROSS JOIN wh_bill w
)

SELECT
  t.tag,
  t.attributed_credits,
  r.reconciled_credits,
  (r.reconciled_credits - t.attributed_credits) AS allocated_idle_or_gap_credits
FROM qah_by_tag t
JOIN reconciled r USING (tag)
ORDER BY r.reconciled_credits DESC;
```

Notes:
- This is a **period-level** reconciliation (not hour-level) and intentionally simple.
- If you need “true” idle-time accounting per warehouse/hour, you need hour-grain timelines (see external approach below) + reconcile carefully for multi-cluster/resizing.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes <=~100ms queries | Under-count in high-throughput/BI “lots of tiny queries” patterns | Compare `QUERY_HISTORY` query counts vs `QUERY_ATTRIBUTION_HISTORY` counts for a window. |
| Up to ~8h latency in `QUERY_ATTRIBUTION_HISTORY` | Recent windows will look artificially low | Add completeness watermark; avoid alerting on last 8–12 hours. |
| No org-wide `QUERY_ATTRIBUTION_HISTORY` | Cross-account cost attribution must use other primitives (warehouse tags + org usage) | Confirm need for per-query org-wide vs per-account. |
| Query-attributed compute excludes other cost classes | Misleading “total cost per query” unless app clearly labels dimensions | Ensure UI/exports separate: warehouse compute vs cloud services vs serverless vs storage vs transfer vs AI. |
| Period-level reconciliation assumes proportional allocation is acceptable | Can misallocate in shared warehouse scenarios with bursty workloads | Offer both modes (attributed-only vs reconciled) and document semantics. |

## Links & Citations

1. Snowflake docs — Attributing cost (tags, join patterns, org-wide limitations): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs — QUERY_ATTRIBUTION_HISTORY reference (365d, latency, exclusions, semantics): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake docs — Exploring compute cost (ACCOUNT_USAGE vs ORGANIZATION_USAGE, USAGE_IN_CURRENCY_DAILY, billing nuance): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Greybeam — Practical per-query cost attribution + explicit note that idle is not included in `QUERY_ATTRIBUTION_HISTORY` and need for custom logic in some cases: https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Decide whether Mission Control app should store a **normalized cost model**:
  - `fact_query_cost_daily` (query_parameterized_hash, query_tag, user_name, credits_attributed_compute)
  - `fact_wh_cost_hourly` (warehouse_id, start_time_hour, credits_used_compute, credits_used_cloud_services)
  - plus dimensions for tags (`TAG_REFERENCES`) and principals.
- Add “semantics toggles” in UI: *Attributed-only* vs *Reconciled-with-idle*.
- Explore how/if Snowflake exposes a first-class idle-time view (some community posts mention `WAREHOUSE_UTILIZATION` enablement via support; treat as non-authoritative until confirmed in docs).
