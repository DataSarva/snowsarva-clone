# Research: FinOps - 2026-02-28

**Time:** 09:06 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution building blocks: metering + tags + org currency)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` returns **hourly credit usage per warehouse** for up to the **last 365 days**. It includes `CREDITS_USED` (compute + cloud services) and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (compute credited to query execution only; **idle time excluded**). Latency can be **up to 180 minutes**, and `CREDITS_USED_CLOUD_SERVICES` latency can be **up to 6 hours**. 
2. `WAREHOUSE_METERING_HISTORY.CREDITS_USED` may be **higher than billed credits** because it does **not** account for cloud services adjustments; Snowflake points to `METERING_DAILY_HISTORY` to determine credits actually billed. (Implication: for “billable” compute, build reconciliations at daily grain.)
3. If you want to reconcile Account Usage views with Organization Usage views, you should set session timezone to **UTC** before querying Account Usage (Snowflake explicitly calls this out for `WAREHOUSE_METERING_HISTORY`).
4. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` contains `QUERY_TAG`, plus attribution dimensions like `WAREHOUSE_NAME`, `ROLE_NAME`, `USER_NAME`, timings, bytes scanned, and other operational metrics. (Implication: `QUERY_TAG` is a first-class join key for attributing *query-level* activity, but warehouse credit usage is still fundamentally warehouse/hour-level.)
5. `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` records **direct** associations between objects and tags (does **not** include tag inheritance). This is usable to discover which objects (including warehouses, depending on supported domains) have which tags/values.
6. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily usage in credits/other units and usage in currency** across an organization, with dimensions including `ACCOUNT_LOCATOR`, `USAGE_DATE` (UTC), `RATING_TYPE`, and `SERVICE_TYPE`. Latency can be **up to 72 hours**, and data can change until month close.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits used per warehouse; includes compute vs cloud services; includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (excludes idle time). Latency up to 3h (cloud services up to 6h). Reconciliation tip: set timezone UTC when comparing to org usage. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level dimensions + `QUERY_TAG` for attribution. Useful for “top queries/users/roles by activity” (but not direct billed credits). |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Tag associations (direct only; no inheritance). Candidate for mapping warehouses → cost centers / teams. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Daily usage + currency charges by account and service type. Useful for producing $-denominated dashboards and for billing reconciliation; latency up to 72h; month-close adjustments possible. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse idle-cost report (hourly → daily rollup):** compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` per warehouse and alert on high idle ratio. This uses only `WAREHOUSE_METERING_HISTORY` and is relatively low-privilege.
2. **Tag-based chargeback for warehouses (credits first):** join `WAREHOUSE_METERING_HISTORY` to `TAG_REFERENCES` (warehouse domain) to roll up credits by `tag_name/tag_value` for “cost center / owner / env”.
3. **Currency overlay (org-level):** enrich the above credits rollups with effective **$ per day per account** using `USAGE_IN_CURRENCY_DAILY` (service type `WAREHOUSE_METERING`) to produce “estimated $ by warehouse/tag”. Keep it explicitly “estimated” unless reconciled to billed credits via daily views.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### SQL Draft: Hourly warehouse credits + idle credits, rolled up by warehouse tag

Assumptions:
- Warehouses can be tagged and appear in `ACCOUNT_USAGE.TAG_REFERENCES` with an appropriate `DOMAIN` value for warehouses (validate in target accounts; domain names vary by object type support).
- This query attributes **hourly credits used** to tags by warehouse; it does not attempt query-level compute apportionment.

```sql
-- Purpose: chargeback / showback by warehouse tag (credits-based)
-- Grain: warehouse_name x hour (then rolled up)
-- Sources:
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES

ALTER SESSION SET TIMEZONE = 'UTC';

WITH metering AS (
  SELECT
    start_time,
    end_time,
    warehouse_id,
    warehouse_name,
    credits_used,
    credits_used_compute,
    credits_used_cloud_services,
    credits_attributed_compute_queries,
    (credits_used_compute - credits_attributed_compute_queries) AS idle_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= dateadd('day', -30, current_timestamp())
),
warehouse_tags AS (
  SELECT
    object_id,
    tag_name,
    tag_value
  FROM snowflake.account_usage.tag_references
  WHERE object_deleted IS NULL
    -- NOTE: validate the warehouse domain string in your account.
    -- If needed, remove DOMAIN filter and inspect distinct domains for your tag_name.
    AND domain ILIKE '%WAREHOUSE%'
)
SELECT
  date_trunc('day', m.start_time) AS usage_day_utc,
  m.warehouse_name,
  t.tag_name,
  t.tag_value,
  SUM(m.credits_used) AS credits_used,
  SUM(m.credits_used_compute) AS credits_used_compute,
  SUM(m.credits_used_cloud_services) AS credits_used_cloud_services,
  SUM(m.credits_attributed_compute_queries) AS credits_attributed_compute_queries,
  SUM(m.idle_credits) AS idle_credits,
  IFF(SUM(m.credits_used_compute) = 0, NULL,
      SUM(m.idle_credits) / SUM(m.credits_used_compute)) AS idle_ratio_of_compute
FROM metering m
LEFT JOIN warehouse_tags t
  ON t.object_id = m.warehouse_id
GROUP BY 1,2,3,4
ORDER BY usage_day_utc DESC, credits_used DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `TAG_REFERENCES.DOMAIN` values (and whether warehouses appear) may differ across accounts and may require specific privileges. | Chargeback-by-tag query might miss warehouses or return incomplete data. | In a test account, run `select distinct domain from snowflake.account_usage.tag_references;` and validate warehouse-tag rows exist. |
| `WAREHOUSE_METERING_HISTORY.CREDITS_USED` is not guaranteed to equal **billed** credits (cloud services adjustments). | Any $ conversion or “billable credits” claim could be wrong. | Use the daily billed views Snowflake recommends (e.g., `METERING_DAILY_HISTORY`) to reconcile. Keep dashboards labeled “usage credits” unless reconciled. |
| Org usage `USAGE_IN_CURRENCY_DAILY` has up to 72h latency and month-close adjustments. | Near-real-time “$ today” dashboards will be delayed and may change later. | Use credits-based near-real-time + currency-based “final-ish” rollups with appropriate watermarking. |
| Reconciliation across `ACCOUNT_USAGE` (local TZ) vs `ORG_USAGE` (UTC) can drift without explicit timezone handling. | Mismatched day boundaries and wrong joins. | Always `ALTER SESSION SET TIMEZONE = UTC` when comparing/merging. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/query_history
3. https://docs.snowflake.com/en/sql-reference/account-usage/tag_references
4. https://docs.snowflake.com/en/user-guide/cost-management-overview
5. https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily

## Next Steps / Follow-ups

- Validate the exact `DOMAIN` values for warehouses in `TAG_REFERENCES` in a real target account; update the query accordingly (and document known-good domain strings).
- Add a second query that reconciles “usage credits” to “billed credits” daily (pull in `METERING_DAILY_HISTORY` per Snowflake guidance) so the app can show both.
- Design a simple watermarking model for UI (e.g., metering data up to now-3h; cloud services up to now-6h; currency view up to now-72h).
