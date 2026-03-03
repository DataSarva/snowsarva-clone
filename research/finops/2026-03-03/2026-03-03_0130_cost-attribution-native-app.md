# Research: FinOps - 2026-03-03

**Time:** 01:30 UTC  
**Topic:** Snowflake FinOps Cost Optimization (warehouse metering + billed credits + tag-based attribution)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and a `CREDITS_USED` that sums the two. It also provides `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which excludes idle time. (Account Usage latency up to ~3 hours; cloud services up to ~6 hours.)
2. `CREDITS_USED` in `WAREHOUSE_METERING_HISTORY` **does not account** for the daily cloud services billing adjustment; Snowflake explicitly directs you to use `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` to determine **credits actually billed**.
3. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` returns **daily** credit usage for many `SERVICE_TYPE` values and includes `CREDITS_BILLED`, which incorporates `CREDITS_ADJUSTMENT_CLOUD_SERVICES` (a negative adjustment).
4. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` records **direct** object↔tag associations only; it **does not include tag inheritance**.
5. Resource monitors can **monitor credit usage for warehouses** and can **notify/suspend** user-managed warehouses when thresholds are reached, but they **do not work for serverless features / AI services**; Snowflake points to **budgets** for those.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes compute vs cloud services; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` for “query-attributed compute” excluding idle time; latency caveats. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily billed credits by `SERVICE_TYPE` with `CREDITS_BILLED` and cloud services adjustment fields. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag associations; no inheritance; can be used for tagging entities like warehouses (domain-dependent). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Per-query metadata including `QUERY_TAG`, `WAREHOUSE_ID/NAME`, and performance/queueing metrics. Useful for “show me the expensive workloads” workflows. |
| `RESOURCE MONITOR` | Object | Snowflake object | Warehouse-only quota/threshold enforcement; does not track serverless/AI spend. |

**Unknown / needs validation (explicit):**
- Whether `WAREHOUSE_METERING_HISTORY.WAREHOUSE_ID` matches `TAG_REFERENCES.OBJECT_ID` when `DOMAIN='WAREHOUSE'` (or equivalent) for tag joins. The docs do not state this explicitly on the pages fetched; treat as a join-key assumption to validate in a real account.

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse cost + idle tax panel:** daily and hourly cost for each warehouse with an “idle cost” series computed as `credits_used_compute - credits_attributed_compute_queries` (where available). Flag top idle offenders.
2. **Billed vs consumed credits reconciliation:** show warehouse consumed credits (hourly) next to account billed credits (daily) and explain (with citations) why they differ (cloud services adjustment + non-warehouse service types).
3. **Tag-based cost attribution v1 (warehouses):** if warehouses are tagged (e.g., `COST_CENTER`, `TEAM`), attribute warehouse credits to tag values by joining metering history to tag references. (Start with direct tag associations only; explicitly call out inheritance limitation.)

## Concrete Artifacts

### Artifact: SQL draft — hourly warehouse credits + idle cost

```sql
-- Hourly cost + idle credits per warehouse (last N days)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- Notes:
--  - CREDITS_USED includes cloud services and may exceed billed credits (see citations)
--  - Idle compute estimate uses CREDITS_USED_COMPUTE - CREDITS_ATTRIBUTED_COMPUTE_QUERIES

SET DAYS_BACK = 14;

SELECT
  start_time,
  end_time,
  warehouse_id,
  warehouse_name,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute_est
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -$DAYS_BACK, CURRENT_TIMESTAMP())
ORDER BY start_time DESC, warehouse_name;
```

### Artifact: SQL draft — daily billed credits by service type (ground truth for billing)

```sql
-- Daily billed credits by service type (last N days)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY

SET DAYS_BACK = 60;

SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_adjustment_cloud_services,
  credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -$DAYS_BACK, CURRENT_DATE())
ORDER BY usage_date DESC, credits_billed DESC;
```

### Artifact: SQL draft — tag-based attribution for warehouse credits (assumption: join key)

```sql
-- Attribute hourly warehouse credits to tag values.
-- Assumptions to validate:
--  1) TAG_REFERENCES contains warehouse tag associations with DOMAIN='WAREHOUSE' (or similar)
--  2) TAG_REFERENCES.OBJECT_ID matches WAREHOUSE_METERING_HISTORY.WAREHOUSE_ID
-- Limitations:
--  - TAG_REFERENCES excludes tag inheritance.

SET DAYS_BACK = 14;
SET TAG_NAME = 'COST_CENTER';

WITH wh_credits AS (
  SELECT
    start_time,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -$DAYS_BACK, CURRENT_TIMESTAMP())
), wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    tag_name,
    tag_value
  FROM snowflake.account_usage.tag_references
  WHERE object_deleted IS NULL
    AND tag_name = $TAG_NAME
    AND domain = 'WAREHOUSE'
)
SELECT
  c.start_time,
  t.tag_name,
  t.tag_value,
  c.warehouse_name,
  c.credits_used
FROM wh_credits c
LEFT JOIN wh_tags t
  ON c.warehouse_id = t.warehouse_id
ORDER BY c.start_time DESC, t.tag_value, c.warehouse_name;
```

### Artifact: Minimal schema for Native App “cost rollups” (draft)

```sql
-- App-owned tables (in an app database/schema) populated by a task / procedure.
-- Goal: decouple UI queries from high-latency ACCOUNT_USAGE scans.

CREATE TABLE IF NOT EXISTS finops_rollup_hourly_warehouse (
  hour_start TIMESTAMP_LTZ NOT NULL,
  hour_end   TIMESTAMP_LTZ NOT NULL,
  warehouse_id NUMBER,
  warehouse_name STRING,
  credits_used_compute NUMBER,
  credits_used_cloud_services NUMBER,
  credits_used NUMBER,
  credits_attributed_compute_queries NUMBER,
  credits_idle_compute_est NUMBER,
  load_ts TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS finops_dim_warehouse_tags (
  warehouse_id NUMBER,
  tag_name STRING,
  tag_value STRING,
  asof_ts TIMESTAMP_LTZ,
  load_ts TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `WAREHOUSE_ID` ↔ `TAG_REFERENCES.OBJECT_ID` join semantics for warehouse tags | If wrong, attribution will be incorrect or null-heavy | Validate by tagging a known warehouse and checking `TAG_REFERENCES` rows + IDs in a test account. |
| Tag inheritance not included in `ACCOUNT_USAGE.TAG_REFERENCES` | Attribution by higher-level tags (db/schema) won’t be visible here | If inheritance is needed, use `INFORMATION_SCHEMA.TAG_REFERENCES()` and/or resolve inheritance logic separately; document the limitation explicitly in UI. |
| ACCOUNT_USAGE latency (2–6 hours depending on view/column) | “Real-time” dashboards will look stale | Use clear “data freshness” indicator; optionally combine with shorter-term telemetry if available. |
| Resource monitors don’t cover serverless / AI services | Warehouse guardrails alone won’t control total spend | Complement with budgets (and/or metering daily history service-type monitoring) for non-warehouse services. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY view (hourly warehouse credits; notes on billed vs used; latency; idle cost example): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. METERING_DAILY_HISTORY view (daily credits; `CREDITS_BILLED`; cloud services adjustment): https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. TAG_REFERENCES view (direct tag↔object associations; no inheritance): https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
4. Working with resource monitors (warehouse-only monitoring; serverless/AI guidance; cloud services adjustment note): https://docs.snowflake.com/en/user-guide/resource-monitors
5. QUERY_HISTORY view (query metadata including `QUERY_TAG`, warehouse columns, and cloud services credits field): https://docs.snowflake.com/en/sql-reference/account-usage/query_history

## Next Steps / Follow-ups

- Validate warehouse-tag join keys in a real account; if mismatched, determine the correct mapping for warehouse tags.
- Decide whether MVP attribution should start with **warehouse tags** (simplest) vs **query_tag-based attribution** (requires query-to-credits allocation logic; more complex).
- Add a “billing reconciliation explainer” section in the app UI: consumed credits vs billed credits, with explicit citations and caveats.
