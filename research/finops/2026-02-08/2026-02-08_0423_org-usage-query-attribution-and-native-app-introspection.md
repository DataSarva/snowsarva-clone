# Research: FinOps - 2026-02-08

**Time:** 0423 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added three new **ORGANIZATION_USAGE premium views** in the org account: **METERING_HISTORY** (hourly credit usage per account), **NETWORK_POLICIES** (network policies across all accounts), and **QUERY_ATTRIBUTION_HISTORY** (attributes warehouse compute costs to specific queries across the organization). These premium views were rolling out and expected to be available to all accounts by **Feb 9, 2026**.
2. In server release **10.3 (Feb 2–5, 2026)**, Snowflake expanded what’s allowed inside **owner’s rights contexts** (explicitly including **Native Apps** and **Streamlit**): most **SHOW**/**DESCRIBE** commands are now permitted, and **INFORMATION_SCHEMA** views/table functions are accessible. Some history functions remain restricted (QUERY_HISTORY*, LOGIN_HISTORY_BY_USER).
3. Snowflake made **listing/share observability** generally available with new real-time **INFORMATION_SCHEMA** objects (LISTINGS, SHARES, AVAILABLE_LISTINGS()) and historical **ACCOUNT_USAGE** objects (LISTINGS, SHARES, GRANTS_TO_SHARES). ACCOUNT_USAGE.ACCESS_HISTORY now captures DDL events for listings/shares and detailed property changes in OBJECT_MODIFIED_BY_DDL.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| ORGANIZATION_USAGE.METERING_HISTORY | view (premium) | ORG_USAGE | Hourly credit usage per account across the org. |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | view (premium) | ORG_USAGE | Computes cost attribution to queries run on warehouses across the org (FinOps gold). |
| ORGANIZATION_USAGE.NETWORK_POLICIES | view (premium) | ORG_USAGE | Useful for governance/compliance drift across accounts; may also support “FinOps guardrails” reporting. |
| <db>.INFORMATION_SCHEMA.LISTINGS | view | INFO_SCHEMA | Real-time; provider-side listing inventory; no deleted objects. |
| <db>.INFORMATION_SCHEMA.SHARES | view | INFO_SCHEMA | Real-time; analogous to SHOW SHARES; inbound + outbound visibility depending on role. |
| <db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS() | table function | INFO_SCHEMA | Real-time discovery surface for consumers (filters like IS_IMPORTED). |
| SNOWFLAKE.ACCOUNT_USAGE.LISTINGS | view | ACCOUNT_USAGE | Historical; includes dropped listings. |
| SNOWFLAKE.ACCOUNT_USAGE.SHARES | view | ACCOUNT_USAGE | Historical; includes dropped shares (provider). |
| SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES | view | ACCOUNT_USAGE | Historical grant/revoke events to shares. |
| SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY | view | ACCOUNT_USAGE | Now captures listing/share DDL lifecycle events + detailed property changes. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-wide cost attribution (query → $) dashboard**: leverage ORG_USAGE.QUERY_ATTRIBUTION_HISTORY to rank “top expensive queries” across *all* accounts, then drill down by account/warehouse/user/app tag. (Previously, this was painful to do consistently org-wide.)
2. **Chargeback / showback exporter**: generate daily/hourly cost allocation tables per account/team/app from ORG_USAGE.METERING_HISTORY + QUERY_ATTRIBUTION_HISTORY; publish to a shared “FinOps” database or external sink.
3. **Native App self-diagnostics (owner’s rights)**: within a Native App, run supported SHOW/DESCRIBE + INFORMATION_SCHEMA lookups to validate prerequisites (objects exist, grants configured, warehouses available) and produce actionable remediation steps—without requiring elevated user roles.

## Concrete Artifacts

### Draft SQL: top attributed compute cost across org

```sql
-- NOTE: column names may differ; validate against docs for ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
-- Goal: find the highest-cost queries across the organization.

SELECT
  account_name,
  start_time,
  warehouse_name,
  user_name,
  query_id,
  query_text,
  credits_attributed  -- (example column)
FROM snowflake.organization_usage.query_attribution_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY credits_attributed DESC
LIMIT 100;
```

### Draft SQL: reconcile account-level credits to query-attributed credits

```sql
-- Goal: compare total hourly credits vs sum(attributed credits) to understand attribution coverage.

WITH hourly AS (
  SELECT
    account_name,
    start_time::timestamp_ntz AS hour_start,
    credits_used  -- (example column)
  FROM snowflake.organization_usage.metering_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
),
attr AS (
  SELECT
    account_name,
    date_trunc('hour', start_time)::timestamp_ntz AS hour_start,
    sum(credits_attributed) AS credits_attributed
  FROM snowflake.organization_usage.query_attribution_history
  WHERE start_time >= dateadd('day', -7, current_timestamp())
  GROUP BY 1,2
)
SELECT
  h.account_name,
  h.hour_start,
  h.credits_used,
  a.credits_attributed,
  (h.credits_used - coalesce(a.credits_attributed, 0)) AS unattributed_credits
FROM hourly h
LEFT JOIN attr a
  ON a.account_name = h.account_name
 AND a.hour_start = h.hour_start
ORDER BY h.hour_start DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE premium views availability may vary by org / rollout schedule (note says by Feb 9, 2026). | Queries may fail or return partial data for some orgs. | Test in target org account; check view existence + permissions. |
| Exact column names/types for QUERY_ATTRIBUTION_HISTORY/METERING_HISTORY may differ from the draft SQL above. | SQL drafts may need adjustment. | Pull full column list from docs / DESCRIBE VIEW. |
| Owner’s-rights contexts still restrict some session/user history functions. | Native App diagnostics must avoid restricted functions and handle errors gracefully. | Validate allowed commands in a minimal Native App + unit tests. |

## Links & Citations

1. New ORG_USAGE premium views (Feb 01, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. 10.3 release notes — expanded owner’s-rights introspection for Native Apps/Streamlit: https://docs.snowflake.com/en/release-notes/2026/10_3#owner-s-rights-contexts-allow-information-schema-show-and-describe
3. Listing/share observability GA (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga

## Next Steps / Follow-ups

- Validate the new ORG_USAGE views in a real org account: permissions required, latency, column definitions, and join keys.
- Prototype a “cost attribution coverage” metric (attributed vs unattributed credits) and define what is expected/acceptable.
- For Native App diagnostics: enumerate a safe subset of SHOW/DESCRIBE + INFO_SCHEMA queries that work in owner’s rights context and map them to actionable checks.
