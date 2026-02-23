# Research: Native Apps - 2026-02-23

**Time:** 1650 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Native Apps “Shareback” is GA (Feb 10, 2026):** a provider app can request consumer permission to share data back to the provider (or designated third parties) via app specifications. This enables governed telemetry/analytics sharing and compliance reporting flows without out-of-band pipelines. 
2. **Native Apps “Inter-App Communication” is Preview (Feb 13, 2026):** a native app can securely communicate with other native apps in the same consumer account, enabling data sharing/merging across apps.
3. **Native Apps “Application Configuration” is Preview (Feb 20, 2026):** a native app can request configuration values from consumers via configuration keys; keys can be marked **sensitive** to avoid exposure in query history/command output.
4. **Two new ACCOUNT_USAGE views (Preview, Feb 18, 2026) expose agent/assistant credit + token usage:**
   - `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` for Snowflake Intelligence interactions
   - `CORTEX_AGENT_USAGE_HISTORY` for Cortex Agent interactions
5. **ORG_USAGE premium views expansion (Feb 01, 2026):** new organization-account premium views include `ORGANIZATION_USAGE.METERING_HISTORY` (hourly credits by account) and `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (attributes compute costs to specific queries across the org).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | ACCOUNT_USAGE | Preview (Feb 18, 2026). Credits/tokens per interaction; includes request/agent metadata. |
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | ACCOUNT_USAGE | Preview (Feb 18, 2026). Credits/tokens per agent call; includes request/agent metadata. |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` | Premium view | ORG_USAGE | Hourly credit usage per account (org account). Rollout noted through Feb 9, 2026. |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | Premium view | ORG_USAGE | Query-level compute attribution across org (org account). Rollout noted through Feb 9, 2026. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Provider Telemetry Shareback” module (Native App):** add an optional post-install step that requests Shareback permission and (once granted) ships consumer telemetry/cost aggregates back to the provider account for fleet-wide benchmarking.
2. **Cross-app “FinOps Baseline Provider” app (Preview-driven):** prototype a small “baseline” app that publishes shared derived tables (e.g., normalized cost model, attribution dims) and allow other apps to read/merge via Inter-App Communication.
3. **Config-driven integrations without leaking secrets:** use Application Configuration (sensitive keys) to collect external identifiers / endpoints / tokens in a way that avoids query-history leakage; wire into existing setup scripts.

## Concrete Artifacts

### Draft: minimal schema for Shareback telemetry

```sql
-- Pseudocode / sketch: consumer account objects the app could create
-- Goal: keep consumer-side footprint small; produce aggregates suitable for shareback.

CREATE OR REPLACE TABLE APP_DB.TELEMETRY_DAILY (
  usage_date DATE,
  app_version STRING,
  warehouse_name STRING,
  credits_used NUMBER(38,9),
  top_query_hash STRING,
  notes VARIANT
);
```

### Draft: monitoring AI/agent spend (ACCOUNT_USAGE)

```sql
-- Preview views; exact columns should be confirmed from docs before shipping.

SELECT
  DATE_TRUNC('day', start_time) AS usage_day,
  user_id,
  agent_id,
  SUM(credits_consumed) AS credits,
  SUM(tokens_total) AS tokens
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1,2,3
ORDER BY 1 DESC, 4 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-App Communication + Application Configuration are **Preview** features. | APIs/behavior may change; limited region/account availability. | Confirm feature flags + docs; test in a non-prod account. |
| Shareback permission model details depend on “app specifications” mechanics. | Incorrect implementation could block install/upgrade flows or be too noisy. | Read “Request data sharing with app specifications”; build a minimal, reversible flow. |
| New ACCOUNT_USAGE views are Preview and column names may differ from our draft SQL. | Dashboards/alerts could break. | Pull the view definitions from docs and pin column set; add defensive SQL. |
| ORG_USAGE premium views require organization account + premium view access. | Not available in all customer setups. | Document prerequisites; fall back to per-account `ACCOUNT_USAGE` when missing. |

## Links & Citations

1. Native Apps Shareback (GA, Feb 10 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Native Apps Inter-App Communication (Preview, Feb 13 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Native Apps Application Configuration (Preview, Feb 20 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. New `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (Preview, Feb 18 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
5. New `CORTEX_AGENT_USAGE_HISTORY` view (Preview, Feb 18 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-cortex-agent-usage-history-view
6. New ORG_USAGE premium views (Feb 01 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
7. Recent feature updates index: https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Read the linked “app specifications” + “inter-app communication” docs and extract the **exact objects/DDL/privileges** required (provider + consumer sides).
- Decide whether to ship Shareback as: (a) opt-in setup step, (b) post-install UI prompt, or (c) separate “telemetry companion” app.
- Add “AI/agent spend” to FinOps dashboards using the new ACCOUNT_USAGE preview views (with fallback when not present).
