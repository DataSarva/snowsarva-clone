# Research: FinOps - 2026-02-16

**Time:** 1535 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added new **ORGANIZATION_USAGE premium views** that provide cross-account visibility in an **organization account**, including (a) hourly credit usage per account and (b) compute-cost attribution to specific queries on warehouses across the org.\
   Source: “Feb 01, 2026: New ORGANIZATION_USAGE premium views”.
2. The new premium views called out are **ORGANIZATION_USAGE.METERING_HISTORY** (hourly credit usage by account) and **ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY** (attributes warehouse compute costs to queries).\
   Source: same as above.
3. Snowflake shipped **Performance Explorer enhancements (Preview)** including: grouped recurring queries tab, filtering by hour, interactive time-window selection, and “previous period” comparisons.\
   Source: “Feb 09, 2026: Performance Explorer enhancements (Preview)”.
4. Snowflake Native Apps now support **Shareback (GA)**: apps can request permission from consumers to share data back to the provider (or designated third parties), positioned for telemetry/analytics sharing and compliance reporting.\
   Source: “Feb 10, 2026: Snowflake Native Apps: Shareback (GA)”.
5. Snowflake Native Apps now support **Inter-App Communication (Preview)**: apps can securely communicate with other apps within the same account, enabling sharing/merging data between apps.\
   Source: “Feb 13, 2026: Snowflake Native Apps: Inter-App Communication (Preview)”.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.METERING_HISTORY` | View (premium) | `ORG_USAGE` | “Returns hourly credit usage for each account in your organization.” Useful for org-level FinOps dashboards + anomaly detection across accounts. |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View (premium) | `ORG_USAGE` | “Attributes compute costs to specific queries run on warehouses in your organization.” Critical for chargeback/showback and “top cost drivers” across accounts. |
| Performance Explorer “By grouped queries” + hour filtering + previous period (Preview) | UI feature | Snowsight | Can be used as a UX reference for our own “cost drivers” & time-slice comparison patterns (even if we implement via SQL + our UI). |
| Native Apps Shareback (GA) | Platform capability | Native Apps | Enables provider-side cost analytics/telemetry ingestion (with consumer permission) to improve recommendations. |
| Native Apps Inter-App Communication (Preview) | Platform capability | Native Apps | Enables integrating a FinOps app with other apps installed in the same account (e.g., share governance posture signals, workload metadata, etc.). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Org-level chargeback/showback (native app feature flag):** If the customer has an org account + premium views enabled, build a “cross-account credit burn” dashboard backed by `ORGANIZATION_USAGE.METERING_HISTORY`.
2. **Query-level cost drivers across accounts:** Use `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` to produce (a) top queries by credits, (b) top warehouses by attributed credits, (c) “new top offenders last 24h vs previous period”.
3. **Native App telemetry loop (opt-in):** If we ship on Marketplace, implement Shareback-based opt-in telemetry sharing so the provider can analyze feature usage + recommendation efficacy (with clear governance & toggles).

## Concrete Artifacts

### SQL sketch: top queries by attributed credits (org-wide)

```sql
-- Assumes run from the ORGANIZATION ACCOUNT with access to premium views.
-- Column names are not listed in release notes; validate against docs for the exact schema.
-- Goal: produce a "top cost drivers" table for last 24h with a previous-period comparison.

WITH cur AS (
  SELECT
    /* account_name, account_locator, warehouse_name, query_id, user_name, ... */
    DATE_TRUNC('HOUR', start_time) AS hr,
    SUM(attributed_credits) AS credits
  FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
  GROUP BY 1 /* + dimensions */
), prev AS (
  SELECT
    DATE_TRUNC('HOUR', start_time) AS hr,
    SUM(attributed_credits) AS credits
  FROM ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('HOUR', -48, CURRENT_TIMESTAMP())
    AND start_time <  DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
  GROUP BY 1 /* + same dimensions */
)
SELECT
  cur.hr,
  cur.credits AS credits_cur,
  prev.credits AS credits_prev,
  (cur.credits - COALESCE(prev.credits, 0)) AS credits_delta
FROM cur
LEFT JOIN prev USING (hr)
ORDER BY credits_delta DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium view availability/entitlement differs by org/account; rollout note says “available to all accounts by Feb 9, 2026”. | Feature may not work everywhere; needs capability detection and graceful degradation. | Check whether org account exists + whether views resolve; document prerequisites in app. |
| Column names/types for `QUERY_ATTRIBUTION_HISTORY` are unknown from the release note excerpt. | SQL implementation details may change. | Pull the view reference docs and confirm schema before implementing. |
| Shareback adoption requires explicit consumer permission and may have Marketplace review considerations. | Telemetry features may slow adoption if not designed carefully. | Design opt-in UX + document data collected; ensure minimal/no PII. |
| Inter-App Communication is Preview. | APIs/behavior may change; limited support/SLA. | Gate behind preview feature flag; avoid hard dependency. |

## Links & Citations

1. Snowflake release note: “Feb 01, 2026: New ORGANIZATION_USAGE premium views” — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Snowflake release note: “Feb 09, 2026: Performance Explorer enhancements (Preview)” — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview
3. Snowflake release note: “Feb 10, 2026: Snowflake Native Apps: Shareback (GA)” — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Snowflake release note: “Feb 13, 2026: Snowflake Native Apps: Inter-App Communication (Preview)” — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac

## Next Steps / Follow-ups

- Pull and pin the exact schemas for `ORGANIZATION_USAGE.METERING_HISTORY` and `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` into a dedicated implementation note (or ADR) once we fetch the reference pages.
- Add an “org-premium-views capability probe” into the app backend so UI can enable/disable org-level FinOps pages automatically.
- Draft provider-side telemetry schema and permission UX based on Shareback GA semantics.
