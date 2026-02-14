# Research: FinOps - 2026-02-14

**Time:** 09:19 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake introduced new ORGANIZATION_USAGE **premium views** in the **organization account** to provide org-wide visibility across accounts.
2. The release note explicitly calls out **ORGANIZATION_USAGE.METERING_HISTORY** (hourly credit usage per account) and **ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY** (attributes warehouse compute cost to queries) as newly available premium views.
3. Premium views in the organization account incur **additional costs** based on records processed; availability depends on contract type (capacity contract by default).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY | ORG_USAGE | Release note + SQL reference | Hourly credit usage per account; premium view (org account). |
| SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | ORG_USAGE | Release note + SQL reference | Compute cost attribution to specific queries (warehouses) at org level; premium view (org account). |
| ORGANIZATION_USAGE premium views (general) | ORG_USAGE | User guide | Additional costs; may require capacity contract or Support for on-demand orgs. |

## MVP Features Unlocked

1. **Org-wide hourly spend dashboard:** per-account hourly credit burn with cross-account rollups and anomaly alerts.
2. **Cross-account “top queries by cost” leaderboards:** unify query-level cost attribution across accounts to find systemic inefficiencies and repeat offenders.
3. **Chargeback/showback v1:** allocate spend by account/warehouse/query with standardized tagging + reporting at the org layer.

## Concrete Artifacts

### Skeleton query ideas (needs column verification)

```sql
-- Hourly credits by account (org-wide)
SELECT *
FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY
-- WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());
;

-- Query-level cost attribution (org-wide)
SELECT *
FROM SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
-- WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());
;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Premium views have incremental cost and may not be enabled for all orgs by default | Surprise spend / access issues | Confirm contract type + access model; measure record processing cost on sample queries. |
| Column sets / semantics may differ from ACCOUNT_USAGE analogs | Incorrect attribution logic | Pull SQL reference pages and validate columns + join keys. |
| Rollout note says “available to all accounts by Feb 9, 2026” | Some orgs may still lag | Verify in target org account: `SHOW VIEWS IN SNOWFLAKE.ORGANIZATION_USAGE;` |

## Links & Citations

1. Feb 01, 2026: New ORGANIZATION_USAGE premium views — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. ORGANIZATION_USAGE schema reference — https://docs.snowflake.com/en/sql-reference/organization-usage
3. Premium views in the organization account — https://docs.snowflake.com/en/user-guide/organization-accounts-premium-views
4. ORG_USAGE.METERING_HISTORY — https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history
5. ORG_USAGE.QUERY_ATTRIBUTION_HISTORY — https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history

## Next Steps / Follow-ups

- Verify exact column names and example queries for both views (from SQL reference pages).
- Estimate incremental cost of querying premium views for our expected workloads; add caching/materialization strategy.
- Design org-level “cost drill-down” UI that pivots: account → warehouse → query attribution.
