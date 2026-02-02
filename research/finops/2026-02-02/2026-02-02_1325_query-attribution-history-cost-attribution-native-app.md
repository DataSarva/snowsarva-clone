# FinOps Research Note — QUERY_ATTRIBUTION_HISTORY: per-query compute cost attribution (and what it unlocks for a FinOps Native App)

- **When (UTC):** 2026-02-02 13:25
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** Snowflake now exposes a first-party, per-query compute-credit attribution view (ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY). That enables a Native App to provide “cost per query/user/tag/query_hash” insights without reconstructing cost heuristics from raw warehouse metering alone, and it clarifies what *isn’t* included (idle time, cloud services, serverless, etc.) so our app can present truthful totals + gaps.

## Accurate takeaways
- **Per-query compute cost is available** via `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` for the last 365 days and can be aggregated by `user_name`, `query_tag`, `query_hash`, etc. The key metric is `CREDITS_ATTRIBUTED_COMPUTE`. It **excludes warehouse idle time**. 
  - Source: `QUERY_ATTRIBUTION_HISTORY view` docs (usage notes + columns). 
- Snowflake’s cost attribution guidance recommends using **object tags** (for resources + users) and **query tags** (for shared apps/workflows) and then joining `TAG_REFERENCES` with metering/attribution views to compute showback/chargeback. 
  - Source: “Attributing cost” docs.
- Snowflake explicitly positions `QUERY_ATTRIBUTION_HISTORY` as enabling attribution “by tag, user, or query hash,” and it was introduced as a new Account Usage view (release note Aug 30, 2024). 
  - Source: 2024-08-30 release note.

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`
  - Latency: up to ~8 hours (per docs).
  - Columns we likely care about in v1: `QUERY_ID`, `WAREHOUSE_ID`, `WAREHOUSE_NAME`, `QUERY_TAG`, `USER_NAME`, `START_TIME`, `END_TIME`, `CREDITS_ATTRIBUTED_COMPUTE`, `CREDITS_USED_QUERY_ACCELERATION`.
  - RBAC note: view should be visible to roles granted `USAGE_VIEWER` or `GOVERNANCE_VIEWER` *database roles* (per docs).
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`
  - Use to compute **total warehouse credits** over time, which includes idle time that `QUERY_ATTRIBUTION_HISTORY` omits (exact semantics: docs show it’s the metering source for credit usage).
- `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`
  - Used to map warehouse/user/object IDs → tag values.
- Optional joins depending on UX:
  - `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` to map hierarchical `query_id`→`root_query_id` for stored-procedure rollups (mentioned in `QUERY_ATTRIBUTION_HISTORY` examples).

## MVP features unlocked (PR-sized)
1) **“Cost by Query Tag” + “Top queries by compute credits”** dashboard powered by `QUERY_ATTRIBUTION_HISTORY` with drilldown: tag → user → query_hash → query_ids.
2) **Idle-time gap reporting:** per-warehouse, compute `idle_credits = metering_credits - attributed_query_credits`, then rank warehouses by “waste” and recommend auto-suspend / resize follow-ups (this bridges the known omission).
3) **Chargeback rollups:** showback by `cost_center` tag on users (and/or warehouses) plus a configurable policy for allocating idle credits.

## Heuristics / detection logic (v1)
- **Attributed query credits (ground truth for query compute):**
  - `SUM(credits_attributed_compute) + SUM(COALESCE(credits_used_query_acceleration,0))` grouped by `{warehouse, tag, user, query_hash, day/hour}`.
- **Warehouse idle credits approximation:**
  - Over the same window, compute `idle_credits = SUM(warehouse_metering_history.credits_used_compute) - SUM(query_attribution_history.credits_attributed_compute)`.
  - Treat negative values as 0 (timing/latency mismatch can produce small negatives).
- **Idle allocation policy (configurable):**
  - Allocate idle credits proportionally to attributed credits by cost center (or by user) within the warehouse/time bucket.
  - Alternative: allocate all idle to the warehouse owner tag (if warehouse is tagged to a single team).

## Security/RBAC notes
- Our Native App will likely need a consumer-side setup that ensures the app can read from `SNOWFLAKE.ACCOUNT_USAGE.*` views. The docs state visibility via `USAGE_VIEWER` or `GOVERNANCE_VIEWER` database roles for `QUERY_ATTRIBUTION_HISTORY`; we should align our install/consent flow with least privilege.
- If we rely on tagging joins (`TAG_REFERENCES`) we must ensure the app can read tag references and that consumers are comfortable exposing tag values to the app UI.

## Concrete artifact — SQL draft: cost_center showback with optional idle allocation

```sql
-- v1: Monthly cost attribution by cost_center tag with optional idle allocation.
-- Requires:
--   - Users are tagged with COST_MANAGEMENT.TAGS.COST_CENTER
--   - Query tags optionally used for app-level attribution
-- Notes:
--   - QUERY_ATTRIBUTION_HISTORY excludes idle time.
--   - Latency can be up to ~8 hours; consider excluding last N hours in production.

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS start_ts,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS end_ts
),

-- Map users -> cost_center (tag references are per object_id + domain)
user_tags AS (
  SELECT
    object_id               AS user_id,
    tag_name,
    tag_value               AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'USER'
    AND tag_name ILIKE 'COST_CENTER'
),

-- Per-query attributed credits, rolled up by user + warehouse
query_cost AS (
  SELECT
    qah.warehouse_id,
    qah.warehouse_name,
    qah.user_name,
    SUM(qah.credits_attributed_compute) AS query_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  JOIN params p
    ON qah.start_time >= p.start_ts
   AND qah.start_time <  p.end_ts
  GROUP BY 1,2,3
),

-- Total metered warehouse credits
warehouse_cost AS (
  SELECT
    wmh.warehouse_id,
    SUM(wmh.credits_used_compute) AS warehouse_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  JOIN params p
    ON wmh.start_time >= p.start_ts
   AND wmh.start_time <  p.end_ts
  GROUP BY 1
),

-- Attribute query credits to user cost_center
user_cost_center_cost AS (
  SELECT
    qc.warehouse_id,
    COALESCE(ut.cost_center, 'UNTAGGED') AS cost_center,
    SUM(qc.query_credits) AS attributed_query_credits
  FROM query_cost qc
  LEFT JOIN user_tags ut
    -- TAG_REFERENCES.object_id for USER is the USER_ID, while QUERY_ATTRIBUTION_HISTORY has USER_NAME.
    -- In v1 we may need a USER_NAME->USER_ID mapping step (e.g., via ACCOUNT_USAGE.USERS).
    -- Placeholder join (to be corrected in implementation).
    ON 1=0
  GROUP BY 1,2
),

-- Join metered warehouse credits and compute idle gap
cost_center_with_idle AS (
  SELECT
    uccc.cost_center,
    SUM(uccc.attributed_query_credits) AS attributed_query_credits,
    SUM(GREATEST(wc.warehouse_credits - uccc.attributed_query_credits, 0)) AS idle_gap_credits_naive
  FROM user_cost_center_cost uccc
  LEFT JOIN warehouse_cost wc
    ON wc.warehouse_id = uccc.warehouse_id
  GROUP BY 1
)

SELECT
  cost_center,
  attributed_query_credits,
  idle_gap_credits_naive,
  attributed_query_credits + idle_gap_credits_naive AS total_credits_with_idle
FROM cost_center_with_idle
ORDER BY total_credits_with_idle DESC;
```

Implementation notes for the draft above:
- We need a **correct join key** from `QUERY_ATTRIBUTION_HISTORY.USER_NAME` → the `TAG_REFERENCES.object_id` for users. The Snowflake docs’ cost attribution examples show user tagging, but the excerpt we pulled doesn’t include the exact join; we should confirm whether `ACCOUNT_USAGE.USERS` (or a similar view) provides `NAME` + `ID` mapping.
- In production, do idle allocation **within a time bucket** (e.g., by hour per warehouse), then roll up; otherwise the “idle gap naive” will double-count across cost centers.

## Risks / assumptions
- **Parallel Extract** returned minimal payload for Snowflake docs in this run; used direct fetch for text while keeping citations limited to URLs discovered via Parallel Search.
- `TAG_REFERENCES` join keys vary by domain; we must validate the exact user identifier mapping in the consumer account.
- Attribution numbers can drift if we don’t align time windows and account for view latency; safest is to exclude the most recent ~8–12 hours.

## Links / references
- https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
- https://docs.snowflake.com/en/user-guide/cost-attributing
- https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution
- (Additional discovered source) https://docs.snowflake.com/en/user-guide/cost-exploring-compute
