# Research: FinOps - 2026-02-27

**Time:** 15:56 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly** credit usage per warehouse for the last **365 days**, including `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed compute credits; does **not** include warehouse idle time).  
2. In `ACCOUNT_USAGE`, `WAREHOUSE_METERING_HISTORY` has latency up to **180 minutes** (and `CREDITS_USED_CLOUD_SERVICES` up to **6 hours**). Snowflake recommends setting `ALTER SESSION SET TIMEZONE = UTC` when reconciling with Organization Usage views.  
3. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` records **direct** tag associations between objects and tags, and explicitly does **not** include tag inheritance. View latency may be up to **120 minutes**.  
4. Resource monitors can control / alert / suspend based on credit usage of **warehouses only**; they can’t track serverless features and AI services (Snowflake documentation points to **Budgets** for those).  
5. Snowflake docs explicitly call out using **tags on warehouses** to enable accurate resource usage monitoring and grouping by cost center / org unit for cost attribution.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly warehouse credits; includes query-attributed compute credits but excludes idle time in `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`. Latency up to ~3h (cloud services credits up to ~6h). |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Mentioned as the place to determine credits actually billed (vs raw `CREDITS_USED`). (Not deep-read in this session.) |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Direct tag associations only; no inheritance; use for warehouse→cost_center style joins. Latency up to ~2h. |
| `RESOURCE MONITOR` | Object | DDL object | Works for warehouses only; supports notification and suspend actions based on credit quota thresholds. |
| `TAG` | Object | Schema object | Tags are key/value pairs attachable to objects (including warehouses); can be queried for usage monitoring / governance. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse cost allocation by tag (hourly + daily rollups):** materialize a daily table that joins warehouse metering to `TAG_REFERENCES` for domains corresponding to warehouses, producing `date, warehouse, cost_center, credits_used_compute, credits_used_cloud_services, idle_credits_estimate`.
2. **Cost-guardrails dashboard:** show resource monitor configuration + actual usage vs quota, and recommend when to prefer Budgets (for serverless/AI/services) vs resource monitors (warehouse). (Link to docs; annotate limitations.)
3. **Tag coverage report (FinOps hygiene):** detect warehouses without required tags (e.g., `cost_center`, `env`, `owner`) using `TAG_REFERENCES` and compare against `SHOW WAREHOUSES` / `ACCOUNT_USAGE` warehouse inventory.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Daily warehouse showback by `cost_center` tag

```sql
-- Goal: allocate warehouse credit usage to a cost_center (or similar) tag.
-- NOTE: TAG_REFERENCES contains only direct assignments (no inheritance).
-- NOTE: WAREHOUSE_METERING_HISTORY is hourly; roll up to day.
-- NOTE: Domain value for warehouses in TAG_REFERENCES should be validated in your account.
--       (Assumption: DOMAIN='WAREHOUSE'.)

ALTER SESSION SET TIMEZONE = 'UTC';

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time) AS hour_start_utc,
    warehouse_id,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS idle_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
),
warehouse_tags AS (
  SELECT
    object_id              AS warehouse_id,
    object_name            AS warehouse_name,
    tag_database,
    tag_schema,
    tag_name,
    tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
    AND tag_name ILIKE 'COST_CENTER'
    AND domain = 'WAREHOUSE'  -- validate
)
SELECT
  TO_DATE(h.hour_start_utc) AS usage_date,
  h.warehouse_name,
  COALESCE(t.tag_value, '__UNSPECIFIED__') AS cost_center,
  SUM(h.credits_used_compute)             AS credits_used_compute,
  SUM(h.credits_used_cloud_services)      AS credits_used_cloud_services,
  SUM(h.idle_compute_credits)             AS idle_compute_credits_estimate,
  SUM(h.credits_used)                     AS credits_used_total
FROM hourly h
LEFT JOIN warehouse_tags t
  ON h.warehouse_id = t.warehouse_id
GROUP BY 1,2,3
ORDER BY usage_date DESC, credits_used_total DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES.DOMAIN` value for warehouses is assumed to be `WAREHOUSE`. | Join may return 0 rows, breaking allocation. | Run `SELECT DISTINCT domain FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES;` and confirm the exact domain name for warehouses. |
| `TAG_REFERENCES` excludes tag inheritance. | If org relies on inherited tags (e.g., account-level → warehouse), costs may appear `__UNSPECIFIED__`. | Compare direct tag coverage vs expected policy; consider supplementing with `TAG_REFERENCES_WITH_LINEAGE` function where available. |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` may exceed billed credits due to cloud services adjustments. | Showback may not reconcile to invoice totals. | Use `METERING_DAILY_HISTORY` for billed credit reconciliation; keep both “raw” and “billed-adjusted” metrics. |
| Latency (2–6h) in usage views. | Dashboards/alerts may be delayed. | Document expected freshness; avoid “real-time” claims; optionally use incremental pipelines + longer lookback. |

## Links & Citations

1. WAREHOUSE_METERING_HISTORY view (columns, latency, idle-cost example, UTC reconciliation note): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. TAG_REFERENCES view (direct associations only; no inheritance; latency): https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
3. Resource monitors limitations (warehouses only; use Budgets for serverless/AI): https://docs.snowflake.com/en/user-guide/resource-monitors
4. Object tagging intro + explicit mention of tagging warehouses for resource usage monitoring: https://docs.snowflake.com/en/user-guide/object-tagging/introduction

## Next Steps / Follow-ups

- Validate `TAG_REFERENCES.DOMAIN` values and confirm warehouse domain label in at least one target customer account.
- Pull and read Snowflake’s “Setting up object tags for cost attribution” page referenced by object tagging docs (`cost-attributing`) and adapt into Native App onboarding UX.
- Decide whether Mission Control should standardize on (a) direct tags only vs (b) lineage-aware tag resolution (function-based) for showback.
