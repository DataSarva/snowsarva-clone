# Research: FinOps - 2026-03-01

**Time:** 23:41 UTC  
**Topic:** Cost attribution primitives we can productize inside a Snowflake FinOps Native App (tags, per-query attribution, billed-vs-consumed caveats, guardrails)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: (a) **object tags** to associate resources/users to a logical unit, and (b) **query tags** to associate *individual queries* to a logical unit when queries are run by a shared application/workflow. This is explicitly positioned as the basis for chargeback/showback. 
2. Within a single account, Snowflake documents cost attribution by joining these **ACCOUNT_USAGE** views: `TAG_REFERENCES` (what’s tagged), `WAREHOUSE_METERING_HISTORY` (warehouse credits), and `QUERY_ATTRIBUTION_HISTORY` (per-query compute credits for warehouse execution). 
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides per-query warehouse compute credits for the last **365 days**, and:
   - can have up to **8 hours** latency,
   - **excludes warehouse idle time**,
   - **excludes** non-warehouse costs (cloud services, serverless features, storage, data transfer, etc.),
   - can exclude **short-running queries (≈<=100ms)**,
   - attributes concurrent-query warehouse cost by a **weighted average** of resource consumption.
4. Snowflake’s own examples show two distinct “truths” we should model in the app:
   - **Metered (warehouse-level) credits** from `WAREHOUSE_METERING_HISTORY` (includes idle time at warehouse level).
   - **Attributed (per-query) credits** from `QUERY_ATTRIBUTION_HISTORY` (excludes idle time). Snowflake provides example SQL that *allocates idle time* proportionally by scaling attributed totals up to match warehouse-level billed/metered totals.
5. `RESOURCE MONITOR`s are warehouse guardrails: they can **monitor and suspend user-managed virtual warehouses**, but they **do not apply to serverless features and AI services** (use budgets for those). They also track cloud-services consumption for thresholding, but limits **do not account for the “10% cloud services adjustment”**.
6. Snowflake’s “Exploring compute cost” guidance notes that many dashboards/views show **credits consumed** without the daily adjustment for cloud services, and suggests using `METERING_DAILY_HISTORY` to determine what was **actually billed** (vs consumed).
7. Snowflake’s compute cost documentation lists `APPLICATION_DAILY_USAGE_HISTORY` as a feature-specific view providing **daily credit usage for Snowflake Native Apps** (last 365 days). This is a strong candidate for a first-party “Native App cost surface” inside our product.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Tag-to-object mapping used for attribution joins. (Doc uses it for warehouses + users.) |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Warehouse credits on an hourly grain; used as warehouse-level “metered” truth. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query attributed warehouse compute credits; excludes idle time; latency up to 8h; 365d retention. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | Used to determine billed cloud-services behavior (docs note many views don’t account for daily adjustment). |
| `SNOWFLAKE.ORGANIZATION_USAGE.*` counterparts | View | ORG_USAGE | Org-wide versions exist for many metering views; **no org-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY` is documented. |
| `RESOURCE MONITOR` objects | Object | DDL | Controls/alerts for warehouse credit consumption only; thresholds don’t reflect cloud-services adjustment. |
| `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | View | ACCOUNT_USAGE | Daily credit usage for Snowflake Native Apps (as listed in compute cost docs). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Attributed vs Metered” reconciliation widget**: For any time window, show (a) per-query attributed credits by query tag / user tag, and (b) metered warehouse credits; compute the delta as “idle/unattributed” and optionally allocate it proportionally (Snowflake’s example approach).
2. **Cost Center coverage report**: Detect untagged warehouses/users by joining `TAG_REFERENCES` with metering / attribution views (Snowflake provides example patterns). Produce “top untagged spend” lists.
3. **Native Apps cost panel (daily)**: First cut UI backed by `ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` for “Native App credits by app/day”, with drill-through to warehouse/query attribution when possible.

## Concrete Artifacts

### SQL: Cost attribution by `QUERY_TAG` with optional idle-time allocation

This follows Snowflake’s documented pattern: sum per-query attributed credits by query_tag, then optionally scale to match warehouse-level metered credits for the same period.

```sql
-- Inputs: time window
SET start_ts = DATEADD('day', -7, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

-- 1) Per-query attribution (excludes idle time)
WITH tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag_norm,
    SUM(credits_attributed_compute)            AS attributed_compute_credits,
    SUM(credits_used_query_acceleration)       AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
  GROUP BY 1
),

-- 2) Warehouse metering (includes idle time at warehouse level)
wh_metered AS (
  SELECT
    SUM(credits_used_compute) AS metered_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
),

-- 3) Total attributed
attrib_total AS (
  SELECT SUM(attributed_compute_credits) AS sum_attributed
  FROM tag_credits
)

SELECT
  tc.query_tag_norm,
  tc.attributed_compute_credits,

  /*
    Optional: allocate idle/unattributed time proportionally by scaling.
    This mirrors Snowflake’s approach in their attribution examples.

    If sum_attributed is 0 (rare edge case), we avoid division by zero.
  */
  IFF(at.sum_attributed > 0,
      (tc.attributed_compute_credits / at.sum_attributed) * wm.metered_compute_credits,
      NULL
  ) AS attributed_plus_idle_allocated,

  tc.qas_credits
FROM tag_credits tc
CROSS JOIN wh_metered wm
CROSS JOIN attrib_total at
ORDER BY attributed_compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` latency up to ~8 hours means near-real-time dashboards can look “underreported”. | Users may distrust the app’s numbers. | Product should label freshness + default windows that avoid the newest ~8h; validate with account telemetry. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and some short-running queries. | “Cost per query” won’t reconcile to warehouse metering unless we explicitly model/allocate the gap. | Implement reconciliation panel + optional proportional allocation; document limitations. |
| Resource monitors don’t apply to serverless and AI services. | “Guardrails” could be incomplete if we only surface resource monitors. | Pair with budgets / serverless cost surfaces; ensure UI makes scope clear. |
| Cloud services daily adjustment (10%) can cause consumed vs billed differences; many views show consumed. | Billing reconciliation confusion. | Use/offer `METERING_DAILY_HISTORY`-based “billed estimate” views; document difference. |
| `APPLICATION_DAILY_USAGE_HISTORY` semantics/columns weren’t inspected in this session (only referenced as a view in docs). | Mis-scoped MVP if the view is less granular than expected. | Follow-up: extract the specific view reference page and inspect columns + latency/retention notes. |

## Links & Citations

1. Snowflake Docs — Attributing cost (tags + query tags + joins to `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, `QUERY_ATTRIBUTION_HISTORY`): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — `QUERY_ATTRIBUTION_HISTORY` view (latency, exclusions, columns, 365d): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — Resource monitors (warehouse-only, cloud services adjustment caveat, triggers): https://docs.snowflake.com/en/user-guide/resource-monitors
4. Snowflake Docs — Exploring compute cost (consumed vs billed caveat; mentions `APPLICATION_DAILY_USAGE_HISTORY` + `METERING_DAILY_HISTORY`): https://docs.snowflake.com/en/user-guide/cost-exploring-compute
5. Snowflake Dev Guide — Query cost monitoring tutorial (example of merging account usage views into a UI tool): https://www.snowflake.com/en/developers/guides/query-cost-monitoring/

## Next Steps / Follow-ups

- Extract and inspect the dedicated reference page for `ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY` (columns, latency, filters), then draft an internal schema for “native app daily cost” tables/views.
- Draft an ADR for our app’s cost model: **Metered vs Attributed vs Billed** and how we reconcile/allocate.
- Add a packaged “Tag hygiene” check: list untagged warehouses/users and top spend under `untagged` query_tag_norm.
