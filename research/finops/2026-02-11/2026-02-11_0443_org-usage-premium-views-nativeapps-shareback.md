# Research: FinOps - 2026-02-11

**Time:** 0443 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added new **ORGANIZATION_USAGE premium views** in the organization account, including:
   - `ORGANIZATION_USAGE.METERING_HISTORY` (hourly credit usage per account)
   - `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (compute credits attributed to individual queries run on warehouses, excluding idle)
   - `ORGANIZATION_USAGE.NETWORK_POLICIES` (network policies across accounts)
   These are rolling out and were expected to be available to all accounts by **Feb 9, 2026**. (Citations: [RN org usage premium views](https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views), [Premium views guide](https://docs.snowflake.com/en/user-guide/organization-accounts-premium-views))

2. `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` includes `QUERY_ID`, `WAREHOUSE_NAME`, `QUERY_TAG`, `USER_NAME`, `START_TIME/END_TIME`, and `CREDITS_ATTRIBUTED_COMPUTE`, and notes **latency up to 24 hours**. (Citation: [QUERY_ATTRIBUTION_HISTORY view](https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history))

3. `ORGANIZATION_USAGE.METERING_HISTORY` provides hourly credits at the org level, with `SERVICE_TYPE` values including (among many others) `WAREHOUSE_METERING`, `SNOWPARK_CONTAINER_SERVICES`, and `TELEMETRY_DATA_INGEST`, which is useful for **org-level burn-rate and service mix** analysis. (Citation: [METERING_HISTORY view](https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history))

4. Snowflake Native Apps now support **Shareback (GA)**: apps can request permission from consumers to share data back to the provider or third parties using listings + app specifications (manifest v2, `CREATE SHARE`/`CREATE LISTING`, LISTING app spec). This enables governed telemetry/analytics flows. (Citations: [RN Native Apps Shareback GA](https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback), [Request data sharing with app specifications](https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing))

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` | View (ORG_USAGE, premium in org account) | Docs | Hourly credits per account; includes `SERVICE_TYPE`, `START_TIME/END_TIME` |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View (ORG_USAGE, premium in org account) | Docs | Per-query attributed compute credits; latency up to 24h; excludes warehouse idle |
| `SNOWFLAKE.ORGANIZATION_USAGE.NETWORK_POLICIES` | View (ORG_USAGE, premium in org account) | Release note | Potential governance/compliance signal (didn’t deep-dive columns in this pass) |
| Native App LISTING app specs + listing-backed share | App capability | Docs | Mechanism for consumer-approved shareback to provider / 3rd party |

## MVP Features Unlocked

1. **Org-level cost attribution dashboard (query-level):**
   - Build a pipeline that reads `ORG_USAGE.QUERY_ATTRIBUTION_HISTORY` daily and produces per-team/per-app cost slices (driven by `QUERY_TAG`, warehouse, user) across *all accounts*.

2. **Hourly burn-rate + anomaly detection across accounts:**
   - Use `ORG_USAGE.METERING_HISTORY` to compute hourly burn rate per account + by `SERVICE_TYPE` to catch spikes (e.g., `SNOWPARK_CONTAINER_SERVICES`, `TELEMETRY_DATA_INGEST`, `WAREHOUSE_METERING`).

3. **Opt-in telemetry/benchmarking for the FinOps Native App (Shareback):**
   - Use Shareback to let consumers opt in to share curated app telemetry (feature usage + savings achieved + anonymized cost KPIs) back to the provider for aggregated benchmarking and product intelligence.

## Concrete Artifacts

### Draft: org-level query cost rollup (skeleton)

```sql
-- Org account context (premium views)
-- Goal: daily rollup of attributed credits by account + query_tag.

SELECT
  account_locator,
  account_name,
  date_trunc('day', start_time) AS day,
  warehouse_name,
  coalesce(query_tag, '(none)') AS query_tag,
  sum(credits_attributed_compute) AS credits_attributed_compute,
  sum(coalesce(credits_used_query_acceleration, 0)) AS credits_qas
FROM snowflake.organization_usage.query_attribution_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
GROUP BY 1,2,3,4,5
ORDER BY day DESC, credits_attributed_compute DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Premium views incur **additional costs** and may require a **capacity contract** (or Support enablement for on-demand orgs). | The app/solution might increase spend if queried too frequently or without aggregation. | Confirm org contract status + measure query patterns. See premium views cost notes. |
| Premium views can take up to **2 weeks** after org account creation to fully backfill 365 days. | Early adopters may see incomplete history. | Check population state and document “data completeness” in UI. |
| `QUERY_ATTRIBUTION_HISTORY` has up to **24h latency** and excludes warehouse idle time. | Not suitable for real-time alerting; may under-represent “total warehouse cost”. | Combine with metering + warehouse metering for totals where needed. |
| Shareback requires listings + app specs workflow and consumer approval. | Adds onboarding friction; needs careful UX + security posture. | Prototype onboarding + legal/security review for telemetry. |

## Links & Citations

1. Feb 01, 2026: New ORGANIZATION_USAGE premium views — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Premium views in the organization account — https://docs.snowflake.com/en/user-guide/organization-accounts-premium-views
3. `ORGANIZATION_USAGE.METERING_HISTORY` — https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history
4. `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` — https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history
5. Feb 10, 2026: Native Apps Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Request data sharing with app specifications — https://docs.snowflake.com/en/developer-guide/native-apps/requesting-app-specs-listing

## Next Steps / Follow-ups

- Validate whether our target customers typically have an **organization account** and whether premium views are enabled.
- Decide on an internal canonical metric: “attributed compute” (query-level) vs “total metering” (includes idle and services).
- Prototype Shareback onboarding UX for “telemetry share” with a clear, minimal data contract.
