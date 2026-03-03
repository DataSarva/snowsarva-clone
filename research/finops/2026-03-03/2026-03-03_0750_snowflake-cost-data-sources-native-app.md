# Research: FinOps - 2026-03-03

**Time:** 07:50 UTC  
**Topic:** Snowflake FinOps cost data sources + attribution primitives (for Native App)
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage (including cloud services adjustment) for the last **365 days**, and includes `SERVICE_TYPE` + `CREDITS_BILLED` so you can determine what was actually billed (vs merely consumed). It has up to ~3 hours latency. [1]
2. `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` provides **daily** usage measured in the organization’s currency (and in credits/TB depending on rating type), but has **high latency (up to 72 hours)** and can change until month close due to adjustments; it’s also unavailable for customers under a reseller contract. [2]
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute** credits (`CREDITS_ATTRIBUTED_COMPUTE`) and optional Query Acceleration credits, but it **excludes warehouse idle time**, excludes non-warehouse costs (cloud services, storage, serverless, AI tokens), and omits very short queries (≈≤100ms). Latency can be up to ~8 hours; full column completeness is available starting mid‑Aug 2024. [3]
4. Snowflake’s recommended cost attribution approach is: use **object tags** for resources/users and **query tags** when an application issues queries on behalf of users; then join `TAG_REFERENCES` + metering views + query attribution views to implement chargeback/showback (optionally distributing idle time proportionally). [4]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | view | `ACCOUNT_USAGE` | Daily billed credits across service types; includes `CREDITS_ADJUSTMENT_CLOUD_SERVICES` and `CREDITS_BILLED`; 1y retention; ~3h latency. [1] |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly credits by service type; useful for intraday analysis; `CREDITS_USED_CLOUD_SERVICES` may lag more than other columns. (Not extracted deeply today; referenced from Account Usage index.) [5] |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | view | `ACCOUNT_USAGE` | Hourly credits at warehouse level; used as “billable warehouse credits” source when distributing idle time. Referenced in attribution examples. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | view | `ACCOUNT_USAGE` | Per-query warehouse compute credits (no idle); includes `QUERY_TAG`, `QUERY_PARAMETERIZED_HASH` for grouping. [3] |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | view | `ACCOUNT_USAGE` | Map tagged objects/users to tag values; used to roll up costs to cost_center/project. [4] |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | view | `ORGANIZATION_USAGE` | Daily cost in currency (with billing/rating/service types); up to 72h latency; retained indefinitely; reseller limitation. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level historical usage/metadata
- `ORG_USAGE` = Organization-level historical usage/metadata
- `INFO_SCHEMA` = Database-level metadata (not used in this note)

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App “Cost Data Health” panel**: show expected freshness for each upstream source (`METERING_DAILY_HISTORY` ~3h, `QUERY_ATTRIBUTION_HISTORY` ~8h, `USAGE_IN_CURRENCY_DAILY` ~72h) and warn when ingestion windows are behind.
2. **Two-lane cost model**: (a) *Fast* daily credits billed (from `METERING_DAILY_HISTORY`) and (b) *Slow* daily currency (from `USAGE_IN_CURRENCY_DAILY`). Present currency numbers as “provisional until month close” and fall back to credits-based estimates when currency is late/unavailable.
3. **Attribution v1 (query-tag based)**: roll up `QUERY_ATTRIBUTION_HISTORY` by `QUERY_TAG` / `QUERY_PARAMETERIZED_HASH` and optionally “true-up” to warehouse metering totals by distributing idle time proportionally, mirroring Snowflake’s documented examples. [4]

## Concrete Artifacts

### ADR-0001: Cost Fact Grain & Truth Sources (FinOps Native App)

**Status:** Draft

**Decision**
- Maintain two canonical facts:
  1) `FACT_DAILY_CREDITS_BILLED` at grain `(usage_date, service_type)` from `ACCOUNT_USAGE.METERING_DAILY_HISTORY`.
  2) `FACT_DAILY_USAGE_CURRENCY` at grain `(usage_date, account_locator, service_type, rating_type, billing_type, is_adjustment, balance_source)` from `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`.

**Why**
- `METERING_DAILY_HISTORY` is the lowest-latency authoritative daily *billed credits* view (includes the cloud services adjustment that many dashboards don’t apply). [1]
- Currency reconciliation is inherently delayed and mutable until month close; it’s appropriate as a separate “slow lane” truth table. [2]

**Consequences**
- UI must support dual timelines: “credits billed” (near-real-time) vs “currency” (lagged).
- For org-wide views, the app may need ORG_USAGE access and must degrade gracefully if org currency view is unavailable (reseller constraint). [2]

### SQL Draft: Build daily billed credits by service type (account scope)

```sql
-- FACT_DAILY_CREDITS_BILLED
-- Source of truth: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- Notes:
--  - credits_billed includes cloud services adjustment
--  - data is per-day; retain at least last 365 days

CREATE OR REPLACE TABLE FINOPS.FACT_DAILY_CREDITS_BILLED AS
SELECT
  usage_date::date                         AS usage_date,
  service_type::varchar                    AS service_type,
  credits_used_compute::number(38,6)       AS credits_used_compute,
  credits_used_cloud_services::number(38,6) AS credits_used_cloud_services,
  credits_adjustment_cloud_services::number(38,6) AS credits_adjustment_cloud_services,
  credits_billed::number(38,6)             AS credits_billed,
  CURRENT_TIMESTAMP()                      AS ingested_at
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -365, CURRENT_DATE());
```

### SQL Draft: Attribute query costs by query_tag and true-up to include idle time

This mirrors the documented approach of distributing idle time proportionally using warehouse metering totals. [4]

```sql
-- INPUTS:
--   - QUERY_ATTRIBUTION_HISTORY: per-query compute credits (excludes idle time)
--   - WAREHOUSE_METERING_HISTORY: warehouse metered compute credits (includes idle time)
-- OUTPUT:
--   - attributed_credits that sum to warehouse metered credits over the time window

WITH
wh_bill AS (
  SELECT
    SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE)
    AND start_time < CURRENT_DATE
),
tag_credits AS (
  SELECT
    COALESCE(NULLIF(query_tag, ''), 'untagged') AS tag,
    SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE)
  GROUP BY 1
),
total_credit AS (
  SELECT SUM(credits) AS sum_all_credits FROM tag_credits
)
SELECT
  tc.tag,
  (tc.credits / NULLIF(t.sum_all_credits, 0)) * w.compute_credits AS attributed_credits_including_idle
FROM tag_credits tc
CROSS JOIN total_credit t
CROSS JOIN wh_bill w
ORDER BY attributed_credits_including_idle DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Org currency view (`USAGE_IN_CURRENCY_DAILY`) has up to 72h latency and can change until month close | “Daily $ spend” will lag and drift; UI must communicate provisional numbers | Confirmed in view usage notes. [2] |
| Some customers cannot access org currency view (reseller contracts) | App must support credits-only mode or account-only mode | Confirmed in view usage notes. [2] |
| Per-query attribution excludes idle time and non-warehouse costs | “Top expensive queries” will not sum to total bill; must support true-up + separate cost buckets | Confirmed in view usage notes + attribution guide. [3][4] |
| Very short queries (≈≤100ms) are excluded from query attribution | Some workloads may appear to have “missing cost” at query level | Confirmed in view usage notes. [3] |
| Reconciliation between ACCOUNT_USAGE and ORGANIZATION_USAGE may require `TIMEZONE=UTC` session setting | Cross-view comparisons can be off by date boundaries | Documented for `METERING_DAILY_HISTORY` reconciliation guidance. [1] |

## Links & Citations

1. Snowflake Docs — `ACCOUNT_USAGE.METERING_DAILY_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
2. Snowflake Docs — `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`: https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily
3. Snowflake Docs — `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
4. Snowflake Docs — Attributing cost (tags + attribution queries): https://docs.snowflake.com/en/user-guide/cost-attributing
5. Snowflake Docs — Account Usage schema index (includes `METERING_HISTORY`, `WAREHOUSE_METERING_HISTORY`, etc.): https://docs.snowflake.com/en/sql-reference/account-usage

## Next Steps / Follow-ups

- Add an explicit **data contracts page** to the Native App: required privileges/roles for each view + expected latency + retention.
- Decide what the app’s “default truth” is when org currency is unavailable: show credits only, or an estimated $ using a configured price/credit.
- Extend the artifact into a **canonical schema** (dimensions + facts) for the app’s internal storage, including: `dim_service_type`, `dim_cost_center`, `dim_query_signature (query_parameterized_hash)`.
