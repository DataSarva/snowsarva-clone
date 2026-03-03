# Research: FinOps - 2026-03-03

**Time:** 16:31 UTC  
**Topic:** Snowflake FinOps Cost Attribution for a Native App (tags + query attribution + idle time)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides hourly credit usage by warehouse for the last 365 days, including `CREDITS_USED_COMPUTE` and `CREDITS_USED_CLOUD_SERVICES`; `CREDITS_USED` is a sum and does **not** include the daily cloud services adjustment, so it can exceed billed credits. (Source: Snowflake docs) [1]
2. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides per-query warehouse compute credit attribution (`CREDITS_ATTRIBUTED_COMPUTE`) but explicitly excludes warehouse idle time and excludes other cost types (e.g., cloud services, storage, serverless features). (Source: Snowflake docs) [2][3]
3. Snowflake’s cloud services usage is billed only if daily cloud services consumption exceeds 10% of daily virtual warehouse usage; this is calculated daily in UTC. Many dashboards and views show credits consumed without accounting for the daily adjustment; `METERING_DAILY_HISTORY` can be used to determine billed credits. (Source: Snowflake docs) [4][5]
4. Snowflake recommends cost attribution using: (a) object tags for resources/users and (b) query tags when an application issues queries on behalf of multiple cost centers. (Source: Snowflake docs) [3]
5. Snowflake’s own “Attributing cost” examples include a pattern to **distribute idle-time credits** (warehouse-billed compute credits minus per-query attributed credits) back to tags/users proportionally to their query-attributed credits. (Source: Snowflake docs) [3]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits (365 days). Includes `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. Latency up to 3h (cloud services up to 6h). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits attributed; excludes idle time; up to ~8h latency; short-running queries (<=~100ms) excluded. [2] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to map tags to warehouses/users for showback/chargeback. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to determine billed credits for cloud services adjustment + daily totals. Mentioned in cost docs. [5] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Converts credits → currency using daily price of a credit. (Org-level; requires organization account access.) [5] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Attributed vs. Billed” toggle in the app**: for a selected time window, show (a) query-attributed compute credits (from `QUERY_ATTRIBUTION_HISTORY`) and (b) warehouse-billed compute credits (from `WAREHOUSE_METERING_HISTORY`), explicitly surfacing the difference as “idle/unattributed compute”. This matches Snowflake’s documented distinction. [1][2][3]
2. **Tag hygiene report**: surface “untagged” spend by joining `TAG_REFERENCES` with `WAREHOUSE_METERING_HISTORY` for warehouse-tagged showback, and by grouping `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG` (using the docs’ `COALESCE(NULLIF(query_tag,''),'untagged')` pattern). [3]
3. **Native App cost-center compatibility layer**: standardize a query-tag format like `COST_CENTER=<value>` (per Snowflake examples) and provide a small helper stored procedure/UDF to set `QUERY_TAG` per session. This creates a stable key for chargeback even when end-users share the same technical user/warehouse. [3]

## Concrete Artifacts

### Artifact: SQL draft — tag-level compute attribution *including idle time*

Goal: produce a single dataset per time window that:
- uses `QUERY_ATTRIBUTION_HISTORY` to get compute credits by `QUERY_TAG` (or “untagged”), **excluding idle time**
- uses `WAREHOUSE_METERING_HISTORY` to get total billed warehouse compute credits for the same window
- re-allocates the “idle/unattributed” portion proportionally across tags (Snowflake’s documented approach)

```sql
-- FINOPS: attribute warehouse compute credits to query tags, including idle time
-- Based on Snowflake's documented pattern for distributing idle-time credits proportionally.
-- Sources: https://docs.snowflake.com/en/user-guide/cost-attributing

-- Parameters (replace with bindings in your Native App)
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

WITH
  wh_bill AS (
    -- Warehouse compute credits actually consumed at the warehouse layer (hourly)
    SELECT
      SUM(credits_used_compute) AS compute_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= $start_ts
      AND start_time <  $end_ts
      AND warehouse_id > 0  -- avoid pseudo warehouses where applicable
  ),

  tag_credits AS (
    -- Per-query attributed compute credits by query tag (excludes idle time by definition)
    SELECT
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
    WHERE start_time >= $start_ts
      AND start_time <  $end_ts
    GROUP BY 1
  ),

  totals AS (
    SELECT SUM(credits) AS sum_all_credits
    FROM tag_credits
  )

SELECT
  tc.tag,
  tc.credits                              AS query_attributed_credits_ex_idle,
  (tc.credits / NULLIF(t.sum_all_credits, 0)) * w.compute_credits
      AS attributed_credits_including_idle,
  w.compute_credits                       AS warehouse_compute_credits_total,
  (w.compute_credits - t.sum_all_credits) AS idle_or_unattributed_compute_credits
FROM tag_credits tc
CROSS JOIN totals t
CROSS JOIN wh_bill w
ORDER BY attributed_credits_including_idle DESC;
```

Notes for the Native App:
- This yields a chargeback-friendly number that reconciles (compute-only) to warehouse metering credits for the window.
- It still does not include non-warehouse costs (serverless, storage, data transfer) by design; those require other views.
- `QUERY_ATTRIBUTION_HISTORY` has latency (up to ~8h) and excludes very short-running queries; expect recent windows to be incomplete. [2]

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short-running queries (<=~100ms). | Tag-level “attributed” totals will be lower than warehouse metering totals unless you explicitly distribute the delta; near-real-time views may lag. | Confirm in docs; validate by comparing aggregates vs metering for last N days in a test account. [2] |
| Cloud services credits shown in warehouse metering are **pre-adjustment** and may not match billed credits; billed cloud services requires daily adjustment logic via `METERING_DAILY_HISTORY`. | If the app claims “billed $”, users may see discrepancies unless we show “consumed” vs “billed” and/or compute billed cloud services separately. | Confirm in docs; add reconciliation queries. [1][4][5] |
| Org-level currency conversion (`USAGE_IN_CURRENCY_DAILY`) requires org account access and is not always available to a Native App running inside a consumer account. | Currency dashboards may be unavailable or limited; app may need “credits-first” UX with optional currency enrichment. | Validate environment constraints per Native App deployment model; feature-flag currency view. [5] |

## Links & Citations

1. Snowflake docs: `WAREHOUSE_METERING_HISTORY` view (ACCOUNT_USAGE) — columns, caveats, idle-time example.
   https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake docs: `QUERY_ATTRIBUTION_HISTORY` view (ACCOUNT_USAGE) — per-query attributed compute credits, latency, exclusions.
   https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake docs: “Attributing cost” — tagging strategy + SQL patterns for cost attribution and distributing idle time.
   https://docs.snowflake.com/en/user-guide/cost-attributing
4. Snowflake docs: “Understanding compute cost” — cloud services 10% adjustment is calculated daily in UTC; billing notes.
   https://docs.snowflake.com/en/user-guide/cost-understanding-compute
5. Snowflake docs: “Exploring compute cost” — dashboards vs usage views; `METERING_DAILY_HISTORY` for billed; `USAGE_IN_CURRENCY_DAILY` for currency.
   https://docs.snowflake.com/en/user-guide/cost-exploring-compute

## Next Steps / Follow-ups

- Draft an ADR for the app’s **Cost Attribution Model** (Consumed vs Attributed vs Billed; and how we handle idle time + cloud services adjustment).
- Identify which of these views are accessible from a Native App running in the consumer account (permissions + database role requirements).
- Add a “Tag enforcement” checklist to governance lane (e.g., block or alert on untagged warehouse creation; require query tag for app sessions).
