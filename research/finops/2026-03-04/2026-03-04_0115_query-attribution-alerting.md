# Research: FinOps - 2026-03-04

**Time:** 01:15 UTC  
**Topic:** Snowflake FinOps Cost Optimization (query-level attribution + idle-time reconciliation)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute credits** for warehouse-executed queries, but **excludes warehouse idle time** and excludes very short-running queries (roughly <= 100ms). It can have up to **~8 hours latency**. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history

2. Snowflake’s recommended chargeback/showback approach is:
   - **object tags** for resources and users (e.g., warehouses, users) and
   - **query tags** when an application issues queries on behalf of multiple cost centers.
   (Snowflake docs)  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing

3. There is **no organization-wide** `ORGANIZATION_USAGE` equivalent of `QUERY_ATTRIBUTION_HISTORY`; it is **account-scoped**. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/user-guide/cost-attributing

4. If you want “billed” compute totals (including the daily cloud services 10% adjustment logic), Snowflake points to `METERING_DAILY_HISTORY` as the queryable source of truth for what’s actually billed. (Snowflake docs)  
   Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute

5. A practical concern (third-party analysis): some users have observed potential mismatches/oddities when reconciling `QUERY_ATTRIBUTION_HISTORY` vs metered credits and have chosen to keep a custom allocation method (including idle time) for accuracy/validation. Treat as a “validate in our account” item, not a doc-guarantee.  
   Source: https://blog.greybeam.ai/snowflake-cost-per-query/

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Query-level compute credits (`CREDITS_ATTRIBUTED_COMPUTE`) excludes idle time; includes QAS credits in separate column; latency up to ~8h. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | ACCOUNT_USAGE | Needed to enrich attribution with query text/type, timings, warehouse metadata, and to compute more realistic execution start (see Greybeam method). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly metered warehouse credits; can be used to reconcile/allocate idle time. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Daily metering incl. cloud services adjustment; recommended to determine what was billed. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Join tags to tagged objects (warehouse/user/etc) for showback/chargeback. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | ACCOUNT_USAGE | Useful for suspend events in idle-time modeling; third-party notes reliability concerns historically (validate). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Attribution Completeness Score** (daily): compare `SUM(credits_attributed_compute)` vs `SUM(credits_used_compute)` per warehouse-hour/month and surface “missing credits” (idle + short queries + latency) as a first-class metric.

2. **Idle-Time Allocation Policy Toggle**: show per-tag/per-user costs in two modes:
   - (A) “Strict query cost” (just `QUERY_ATTRIBUTION_HISTORY`), and
   - (B) “All-in warehouse cost” (distribute idle time proportionally based on attributed credits).
   Snowflake already provides the proportional-distribution pattern for users/tags; we can productize it with guardrails.

3. **Query Attribution Anomaly Detector**: detect hours where `query_attributed_credits / metered_credits` is unexpectedly high (or > 1), and recommend validation steps (support ticket, check warehouse-id alignment, examine concurrency/QAS).

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: “All-in” cost by query tag (distribute idle time)

Goal: Provide a single dataset for dashboards that reconciles to warehouse metering while still enabling chargeback by `QUERY_TAG`.

Key concept from Snowflake docs: distribute idle credits proportionally based on usage (attributed credits) so totals match metering. (Docs show this pattern for users and tags.)

```sql
-- Inputs:
--  - QUERY_ATTRIBUTION_HISTORY: per-query credits excluding idle time
--  - WAREHOUSE_METERING_HISTORY: hourly warehouse credits (includes idle)
--
-- Output: per-query_tag credits that reconcile to metering for the period.
-- Notes:
--  - This distributes *all* metered credits (including idle) proportionally by query_tag.
--  - Treat empty query_tag as 'untagged'.

WITH
params AS (
  SELECT
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS start_ts,
    CURRENT_TIMESTAMP() AS end_ts
),

-- Metered credits for the period (all warehouses)
wh_bill AS (
  SELECT
    SUM(wmh.credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  JOIN params p
    ON wmh.start_time >= p.start_ts
   AND wmh.start_time <  p.end_ts
),

-- Query-attributed credits (exclude idle) aggregated by tag
-- (also includes QAS separately if you want to add it)
tag_credits AS (
  SELECT
    COALESCE(NULLIF(qah.query_tag, ''), 'untagged') AS tag,
    SUM(qah.credits_attributed_compute)            AS query_exec_credits,
    SUM(qah.credits_used_query_acceleration)      AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  JOIN params p
    ON qah.start_time >= p.start_ts
   AND qah.start_time <  p.end_ts
  GROUP BY 1
),

total_query_exec AS (
  SELECT SUM(query_exec_credits) AS total_query_exec_credits
  FROM tag_credits
)

SELECT
  tc.tag,
  tc.query_exec_credits,
  tc.qas_credits,
  -- Distribute *metered* credits (includes idle) in proportion to query_exec_credits.
  -- This is the core 'all-in' attribution.
  (tc.query_exec_credits / NULLIF(tq.total_query_exec_credits, 0))
    * wb.metered_compute_credits AS all_in_compute_credits
FROM tag_credits tc
CROSS JOIN total_query_exec tq
CROSS JOIN wh_bill wb
ORDER BY all_in_compute_credits DESC;
```

### SQL Draft: Warehouse-hour reconciliation + anomaly flags

```sql
-- Flags hours where query-attributed credits exceed metered credits or are unexpectedly high.
-- Useful as a monitoring primitive in the FinOps app.

WITH qah_hour AS (
  SELECT
    warehouse_id,
    warehouse_name,
    DATE_TRUNC('HOUR', start_time) AS hour,
    SUM(credits_attributed_compute) AS query_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
),
wmh_hour AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time AS hour,
    SUM(credits_used_compute) AS metered_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
)
SELECT
  COALESCE(w.warehouse_id, q.warehouse_id) AS warehouse_id,
  COALESCE(w.warehouse_name, q.warehouse_name) AS warehouse_name,
  COALESCE(w.hour, q.hour) AS hour,
  w.metered_credits,
  q.query_credits,
  (q.query_credits / NULLIF(w.metered_credits, 0)) AS query_to_metered_ratio,
  CASE
    WHEN w.metered_credits IS NULL THEN 'MISSING_METERING'
    WHEN q.query_credits IS NULL THEN 'NO_ATTRIBUTED_QUERIES'
    WHEN q.query_credits > w.metered_credits * 1.05 THEN 'ATTRIBUTED_GT_METERED'
    WHEN q.query_credits > w.metered_credits * 0.95 THEN 'ATTRIBUTED_CLOSE_TO_METERED'
    ELSE 'OK_OR_IDLE_HEAVY'
  END AS status
FROM wmh_hour w
FULL OUTER JOIN qah_hour q
  ON w.warehouse_id = q.warehouse_id
 AND w.hour = q.hour
ORDER BY hour DESC, query_to_metered_ratio DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` latency (up to ~8h) means “today” dashboards can look incomplete. | False alarms / noisy anomaly detection. | Build detection windows with a lag (e.g., only alert on hours older than 12h). Source: query attribution docs. |
| Short queries (<= ~100ms) are excluded from `QUERY_ATTRIBUTION_HISTORY`. | Under-attribution for chatty workloads; “missing credits” could be expected. | Quantify % of queries under threshold via `QUERY_HISTORY` and correlate to missing credits. Source: query attribution docs. |
| Reconciliation anomalies might be account-specific and/or due to product nuances (e.g., concurrency, resizing, QAS). | We might overfit to third-party observations. | Run the reconciliation SQL above in a real customer/sandbox account; file support ticket if ratios look wrong. Source: Greybeam post + our measurements. |
| Organization-wide per-query attribution isn’t possible from `ORG_USAGE` (no org-level equivalent view). | Multi-account FinOps app needs per-account processing or replicated results. | Treat as architecture constraint; confirm in docs. Source: cost-attributing docs. |

## Links & Citations

1. Snowflake docs: `QUERY_ATTRIBUTION_HISTORY` view (columns, latency, exclusions): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
2. Snowflake docs: Attributing cost (tags + query tags; patterns; no org-wide query attribution view): https://docs.snowflake.com/en/user-guide/cost-attributing
3. Snowflake docs: Exploring compute cost (metering views; billed cloud services adjustment; schema notes): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
4. Greybeam analysis: query cost attribution + idle-time allocation approach + potential discrepancies: https://blog.greybeam.ai/snowflake-cost-per-query/

## Next Steps / Follow-ups

- Implement an internal “Attribution Completeness Score” metric (by warehouse-hour and month) and wire it into the Native App UI as a health check.
- Validate whether `WAREHOUSE_EVENTS_HISTORY` is sufficiently reliable for idle-time modeling in our target accounts; if not, fall back to purely metering-based proportional allocation.
- Decide product stance: show both (A) strict query costs and (B) all-in warehouse costs, with explicit explanations and reconciliation proof.
