# Research: FinOps - 2026-03-03

**Time:** 05:45 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended cost attribution approach is: use **object tags** to associate resources/users to cost centers, and use **query tags** when a shared application issues queries on behalf of multiple cost centers. 
2. For **per-query warehouse compute attribution**, Snowflake provides `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` and explicitly notes: (a) attribution is based on **warehouse credit usage for executing the query**, (b) it **does not include warehouse idle time**, and (c) it does **not include** other categories like storage, data transfer, cloud services, or serverless feature costs. 
3. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly credits** per warehouse (up to 365 days) and includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which covers query execution cost but **excludes idle**; Snowflake provides an example calculating idle cost as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`.
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes dimensions needed for spend investigations (warehouse/user/role/query tag/etc.) and includes a `CREDITS_USED_CLOUD_SERVICES` column; Snowflake notes this value **does not** account for the daily cloud services billing adjustment and recommends using `METERING_DAILY_HISTORY` to determine what was actually billed.
5. For organization-level rollups across accounts, Snowflake states: (a) `ORGANIZATION_USAGE` has organization-wide metering views, (b) `TAG_REFERENCES` is only available in the **organization account**, and (c) there is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Used to find tag assignments on objects (e.g., `domain='WAREHOUSE'` / `domain='USER'`). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits per warehouse; includes `CREDITS_USED*` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle). Latency up to 180 minutes; cloud services column can lag longer. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query warehouse compute attribution; excludes idle + non-warehouse cost categories. No `ORG_USAGE` equivalent per Snowflake docs. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | 365 days of query history; includes `QUERY_TAG` and `CREDITS_USED_CLOUD_SERVICES` (not adjusted for billing). Latency up to ~45 minutes. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Used to compute “billed cloud services” (after adjustment). Mentioned as the way to determine what was actually billed. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Org-wide warehouse metering (useful for showback for dedicated resources). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Idle cost allocator (warehouse-level)**: compute idle credits per warehouse and allocate them back to cost centers proportional to their query-attributed credits, producing “fully-loaded” warehouse chargeback (compute + allocated idle).
2. **Tag coverage + drift report**: detect untagged warehouses/users and “untagged” query_tag usage, to enforce governance around attribution.
3. **Cloud services billed-vs-consumed alert**: for a given day, compute whether cloud services exceeded the 10% threshold using `METERING_DAILY_HISTORY`, and surface days where the adjustment changes the billed amount materially.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Fully-loaded warehouse chargeback by cost_center (allocate idle proportionally)

Assumptions:
- Warehouses are shared across cost centers.
- Cost centers are applied as **user tags** (`domain='USER'`) OR can be adapted to query tags.
- We allocate **idle compute** at the warehouse level proportionally to each cost center’s `credits_attributed_compute`.

```sql
-- Fully-loaded warehouse compute chargeback by cost center (includes allocated idle)
-- Source views:
--   - SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
--   - SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--   - SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES

-- Choose analysis window
SET start_ts = DATEADD('day', -30, CURRENT_TIMESTAMP());
SET end_ts   = CURRENT_TIMESTAMP();

WITH cost_center_by_user AS (
  SELECT
      object_name AS user_name,
      tag_name,
      tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'USER'
    AND UPPER(tag_name) IN ('COST_CENTER','COST_CENTRE')  -- adjust for your tag naming
),

q_cost AS (
  SELECT
      DATE_TRUNC('day', qah.start_time) AS usage_day,
      qah.warehouse_name,
      COALESCE(cc.tag_value, 'untagged') AS cost_center,
      SUM(qah.credits_attributed_compute) AS attributed_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
  LEFT JOIN cost_center_by_user cc
    ON cc.user_name = qah.user_name
  WHERE qah.start_time >= $start_ts
    AND qah.start_time <  $end_ts
  GROUP BY 1,2,3
),

wh_meter AS (
  SELECT
      DATE_TRUNC('day', start_time) AS usage_day,
      warehouse_name,
      SUM(credits_used_compute) AS wh_compute_credits,
      SUM(credits_attributed_compute_queries) AS wh_attrib_query_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= $start_ts
    AND start_time <  $end_ts
    AND warehouse_id > 0  -- skip pseudo warehouses like CLOUD_SERVICES_ONLY
  GROUP BY 1,2
),

idle AS (
  SELECT
      usage_day,
      warehouse_name,
      GREATEST(wh_compute_credits - wh_attrib_query_credits, 0) AS idle_compute_credits
  FROM wh_meter
),

q_cost_with_totals AS (
  SELECT
      qc.*,
      SUM(qc.attributed_compute_credits) OVER (PARTITION BY usage_day, warehouse_name) AS wh_total_attrib_credits
  FROM q_cost qc
)

SELECT
    qc.usage_day,
    qc.warehouse_name,
    qc.cost_center,
    qc.attributed_compute_credits,
    i.idle_compute_credits,
    CASE
      WHEN qc.wh_total_attrib_credits > 0
        THEN qc.attributed_compute_credits / qc.wh_total_attrib_credits * i.idle_compute_credits
      ELSE 0
    END AS allocated_idle_compute_credits,
    qc.attributed_compute_credits
      + CASE
          WHEN qc.wh_total_attrib_credits > 0
            THEN qc.attributed_compute_credits / qc.wh_total_attrib_credits * i.idle_compute_credits
          ELSE 0
        END AS fully_loaded_compute_credits
FROM q_cost_with_totals qc
JOIN idle i
  ON i.usage_day = qc.usage_day
 AND i.warehouse_name = qc.warehouse_name
ORDER BY usage_day DESC, warehouse_name, fully_loaded_compute_credits DESC;
```

Notes:
- This produces “fully-loaded” credits, but **still excludes**: storage, data transfer, most serverless features, and cloud services billing adjustments (per Snowflake’s attribution guidance).
- Consider adding a second stage to incorporate serverless feature costs by cost center where possible (object-tagged resources for features like Automatic Clustering / Search Optimization, etc.).

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Tag strategy differs (cost center on warehouses vs users vs query tags) | Joins may fail or attribution may be misleading | Confirm tag domains and naming conventions; sample from `TAG_REFERENCES`. |
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time by design | Without an allocator, chargeback undercounts shared warehouse cost | Use warehouse-level idle calculation from `WAREHOUSE_METERING_HISTORY` and decide allocation policy. |
| `CREDITS_USED_CLOUD_SERVICES` is “consumed” not “billed” | Reporting can disagree with invoices | Use `METERING_DAILY_HISTORY` for billed determination as Snowflake recommends. |
| View latency (45m+ for QUERY_HISTORY, up to hours for metering) | Near-real-time dashboards may be wrong | Implement data freshness UI + backfill logic; use time windows with safety buffers. |
| No org-wide `QUERY_ATTRIBUTION_HISTORY` | Cross-account per-query attribution is not available centrally | Limit per-query chargeback to account scope; use org-wide metering for dedicated resources. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/cost-attributing
2. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
3. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
4. https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Pull Snowflake docs for `QUERY_ATTRIBUTION_HISTORY` and `USAGE_IN_CURRENCY_DAILY` specifically, to extend the allocator into $ (currency) and validate column names/semantics.
- Decide a “default allocation policy” for idle (proportional to attributed credits vs equal split vs business rules) and capture as an ADR.
- Add a governance check that ensures every warehouse/user has the cost_center tag and every shared app sets `QUERY_TAG`.
