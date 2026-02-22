# Research: Native Apps - 2026-02-21

**Time:** 22:26 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake’s release notes list multiple Native App-related feature updates in mid-Feb 2026, including **Shareback (GA)**, **Inter-App Communication (Preview)**, and **Configuration (Preview)**.
2. Snowflake’s release notes also list a **Preview** for “Sharing Streamlit in Snowflake apps,” which likely impacts Native App UX distribution patterns.
3. For FinOps/observability-adjacent use cases, Snowflake’s release notes list new **ACCOUNT_USAGE** views in **Preview**: `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` and `CORTEX_AGENT_USAGE_HISTORY`.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY | ACCOUNT_USAGE | Release notes (Feature updates) | New view listed as Preview (Feb 18, 2026). Column set/semantics need doc deep-dive. |
| SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY | ACCOUNT_USAGE | Release notes (Feature updates) | New view listed as Preview (Feb 18, 2026). Useful for agent/cortex cost attribution. |

## MVP Features Unlocked

1. **Native App “Shareback readiness” checker**: detect whether an installed app can use shareback workflows; surface prerequisites and current enablement status.
2. **Inter-App communication demo + governance guardrails**: sample pattern and policy checks for composing multiple apps safely (Preview → build “feature flag” layer).
3. **Cortex / Intelligence usage dashboards**: add ingestion + daily rollups for the new usage-history views to improve cost attribution for AI features.

## Concrete Artifacts

### Proposed ingestion scaffold for new ACCOUNT_USAGE views

```sql
-- Placeholder: verify object names + availability in target accounts/regions.
-- Goal: daily rollup for cost attribution / usage telemetry.

create or replace table finops_intelligence_usage_daily as
select
  date_trunc('day', start_time) as usage_day,
  /* TODO: dimensions once we fetch schema: user_name, role_name, warehouse_name, model_name, etc. */
  count(*) as events
from snowflake.account_usage.snowflake_intelligence_usage_history
group by 1;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| “Configuration (Preview)” details are not captured on the summary page | Might mis-scope what configuration actually means (app config vs runtime config vs packaging) | Open the specific feature update entry / linked doc page and extract details + API/SQL changes. |
| New ACCOUNT_USAGE view schemas may vary / require enablement | Dashboards/ETL could break or be unavailable | Query `INFORMATION_SCHEMA.VIEWS` / attempt `DESC VIEW` in a test account; confirm required privileges/editions. |
| Preview features may change names/semantics | Engineering churn | Gate behind feature flags; isolate in connector module. |

## Links & Citations

1. Snowflake server release notes and feature updates (includes Feb 10–20, 2026 feature updates list): https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Pull the specific doc pages for:
  - Native Apps: Shareback (GA)
  - Native Apps: Inter-App Communication (Preview)
  - Native Apps: Configuration (Preview)
  - Sharing Streamlit in Snowflake apps (Preview)
- For the two new ACCOUNT_USAGE views, capture:
  - full schema
  - retention window
  - dimensions for attribution (user/role/warehouse/database/schema/app)
  - any required enablement / edition constraints
