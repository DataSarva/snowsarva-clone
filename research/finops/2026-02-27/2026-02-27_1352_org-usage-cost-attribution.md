# Research: FinOps - 2026-02-27

**Time:** 13:52 UTC  
**Topic:** Org-wide Snowflake cost attribution architecture (tags + ACCOUNT_USAGE vs ORGANIZATION_USAGE)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s recommended pattern for chargeback/showback is to use **object tags** (e.g., on warehouses/users) and optionally **query tags** (QUERY_TAG session parameter) to attribute spend to cost centers/projects. [1]
2. **QUERY_ATTRIBUTION_HISTORY** (in `SNOWFLAKE.ACCOUNT_USAGE`) can be used to estimate **per-query warehouse compute cost**, and it explicitly **excludes warehouse idle time** and **excludes very short queries (≈<=100ms)**. Latency can be up to **8 hours**. [2]
3. Snowflake supports cost attribution **across accounts** in an org using `SNOWFLAKE.ORGANIZATION_USAGE` equivalents for some views (e.g., `WAREHOUSE_METERING_HISTORY`) **for resources not shared**, but there is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY` today. [1]
4. `METERING_HISTORY` (account-level) provides hourly credits by **SERVICE_TYPE** across compute categories (warehouses, serverless, SCS, etc.) with documented latency (typically up to ~3 hours; some columns/types longer). [3]
5. The `WAREHOUSE_METERING_HISTORY` **table function** returns warehouse hourly credits within the last 6 months, but Snowflake recommends using the **ACCOUNT_USAGE view** for completeness across longer time ranges. [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | ACCOUNT_USAGE | Join tags to warehouses/users; also used in attribution examples. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | Warehouse hourly credits (compute/cloud services). Used as “bill” source in examples. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | ACCOUNT_USAGE | Per-query attributed credits (compute + optional QAS credits), excludes idle time; 8h latency; short queries omitted. [2] |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | ORG_USAGE | Org-wide warehouse metering (for cross-account rollups); usable for “not shared” resources when joined to org tag refs. [1] |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | View | ORG_USAGE | Only available in the organization account; enables org-wide tag joins (for supported scenarios). [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | ACCOUNT_USAGE | Hourly credits by service type across account; useful to reconcile non-warehouse/serverless categories. [3] |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(...)` | Table function | INFO_SCHEMA | 6-month window; use for targeted point queries / quick UI or tests, not canonical datasets. [4] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Cost Attribution “Coverage Map” panel**: show which portions of spend are attributable by tags at (a) org level (dedicated warehouses) vs (b) per account level (shared warehouses, per-query). Explicitly call out the gaps (no org-wide per-query attribution). Backed by metadata discovery queries.
2. **Idle-time allocator module**: implement Snowflake’s documented pattern to distribute idle warehouse credits across cost centers proportional to attributed query credits (within an account), producing a “with idle” and “without idle” view. [1][2]
3. **Service-type budget breakdown**: build account-level dashboards using `METERING_HISTORY` by `SERVICE_TYPE` to show and budget for serverless features (tasks, alerts, search optimization, SCS, etc.) separately from warehouse metering. [3]

## Concrete Artifacts

### Artifact: Minimal architecture + SQL building blocks for org-wide attribution

#### 1) Org-wide attribution for **dedicated (not shared)** resources (warehouse-level tagging)

This is the “easy win”: if a warehouse is exclusively owned by one cost center, tag the warehouse and join metering to tags.

```sql
-- Org account context (organization account)
-- Attribute warehouse compute credits across ALL accounts *when warehouses are dedicated*
-- (based on Snowflake doc pattern; adapted to org-wide usage)

SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits
FROM snowflake.organization_usage.warehouse_metering_history AS wmh
LEFT JOIN snowflake.organization_usage.tag_references AS tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
 -- If you use a replicated/shared tag DB, you may need to filter tag_database/tag_schema
WHERE wmh.start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
  AND wmh.start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY total_credits DESC;
```

Notes:
- Snowflake explicitly documents an org-wide variant for this “resources not shared by departments” scenario using ORG_USAGE views. [1]

#### 2) Per-account attribution for **shared** resources (per-query)

When a warehouse is shared by multiple cost centers, Snowflake’s documented approach is per-query attribution using `QUERY_ATTRIBUTION_HISTORY` + tagging users (or using query tags). This can only be done **within one account at a time**. [1]

```sql
-- Account context (run inside each account)
-- Example: attribute query compute credits to USER cost_center tags (excluding idle time)

WITH joined_data AS (
  SELECT
    tr.tag_name,
    tr.tag_value,
    qah.credits_attributed_compute,
    qah.start_time
  FROM snowflake.account_usage.tag_references AS tr
  JOIN snowflake.account_usage.query_attribution_history AS qah
    ON tr.domain = 'USER'
   AND tr.object_name = qah.user_name
)
SELECT
  tag_name,
  tag_value,
  SUM(credits_attributed_compute) AS total_credits_ex_idle
FROM joined_data
WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE)
  AND start_time <  CURRENT_DATE
GROUP BY 1, 2
ORDER BY 1, 2;
```

Key limitations to surface in-product:
- `QUERY_ATTRIBUTION_HISTORY` excludes idle time and short-running queries (≈<=100ms). [2]
- Latency can be up to 8 hours. [2]
- There is no ORG_USAGE equivalent; cross-account rollups require a per-account collection/aggregation strategy. [1]

#### 3) “With idle time” attribution (within an account)

Snowflake documents an approach to distribute idle warehouse credits that are not captured in per-query costs, by allocating the warehouse’s metered credits proportionally to each tag’s share of attributed query credits. [1][2]

```sql
-- Account context: allocate warehouse metering credits (incl. idle) across QUERY_TAG values
-- by proportional share of credits_attributed_compute.

WITH
  wh_bill AS (
    SELECT SUM(credits_used_compute) AS compute_credits
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE)
      AND start_time <  CURRENT_DATE
  ),
  tag_credits AS (
    SELECT
      COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
      SUM(credits_attributed_compute) AS credits
    FROM snowflake.account_usage.query_attribution_history
    WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE)
    GROUP BY 1
  ),
  total_credit AS (
    SELECT SUM(credits) AS sum_all_credits
    FROM tag_credits
  )
SELECT
  tc.tag,
  tc.credits / t.sum_all_credits * w.compute_credits AS attributed_credits_with_idle
FROM tag_credits tc, total_credit t, wh_bill w
ORDER BY attributed_credits_with_idle DESC;
```

#### 4) Non-warehouse / serverless / feature costs: use `METERING_HISTORY`

This is a separate axis from warehouse chargeback. `METERING_HISTORY` is useful for a “what’s driving total credits” breakdown by service type. [3]

```sql
-- Account context: monthly credits by SERVICE_TYPE
SELECT
  TO_DATE(start_time) AS usage_date,
  service_type,
  SUM(credits_used) AS credits
FROM snowflake.account_usage.metering_history
WHERE start_time >= DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE))
  AND start_time <  DATE_TRUNC('MONTH', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY usage_date, credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Org-wide cost attribution” is possible for shared resources via ORG_USAGE per-query views | Would enable simpler product experience (single org query) | Snowflake docs explicitly state there is **no ORG_USAGE equivalent** for `QUERY_ATTRIBUTION_HISTORY`; treat as not available until proven otherwise. [1] |
| Tag references are consistent across accounts when tags are replicated | If inconsistent, org rollups may mis-attribute or show “untagged” | Validate replication strategy + enforce tag DB/schema filters in joins; docs show a replication approach for tags. [1] |
| Proportional allocation is “good enough” for idle time attribution | Could misrepresent cost when usage is bursty or warehouses resize | Offer both “ex idle” and “with idle” metrics and document methodology; use Snowflake’s documented approach as default. [1][2] |

## Links & Citations

1. Snowflake Docs — *Attributing cost* (tags + scenarios + org vs account limitations + example SQL): https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake Docs — *QUERY_ATTRIBUTION_HISTORY view* (latency, excludes idle time, short queries excluded): https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
3. Snowflake Docs — *METERING_HISTORY view* (hourly credits by SERVICE_TYPE + latency notes): https://docs.snowflake.com/en/sql-reference/account-usage/metering_history
4. Snowflake Docs — *WAREHOUSE_METERING_HISTORY table function* (6-month note; prefer ACCOUNT_USAGE view for complete dataset): https://docs.snowflake.com/en/sql-reference/functions/warehouse_metering_history
5. Snowflake Release Notes — *Aug 30, 2024 — Query attribution costs* (introduces `QUERY_ATTRIBUTION_HISTORY`): https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution

## Next Steps / Follow-ups

- Design an internal **attribution data contract** for the Native App:
  - inputs: tags + account usage views (per account) + org usage views (org account)
  - outputs: a unified “cost center daily credits” fact table with columns `{day, account_name, cost_center, credits_compute_ex_idle, credits_compute_with_idle, credits_by_service_type_json}`
- Add a “coverage/limitations” banner in UI: per-query attribution is account-scoped; org-wide only for dedicated resources.
- Explore whether Snowflake has added (or plans to add) premium ORG_USAGE views for per-query attribution; treat as roadmap watch.
