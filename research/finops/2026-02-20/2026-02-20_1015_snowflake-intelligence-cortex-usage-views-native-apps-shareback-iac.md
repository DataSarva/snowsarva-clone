# Research: FinOps - 2026-02-20

**Time:** 10:15 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added a new `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (Preview) that exposes credit consumption for Snowflake Intelligence interactions, with per-agent-call rows and metadata such as user ID, request ID, Snowflake Intelligence ID, and agent ID. 
2. Snowflake added a new `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` view (Preview) that exposes credit consumption for Cortex Agents interactions, with per-agent-call rows and metadata such as user ID, request ID, and agent ID.
3. Snowflake Native Apps now support **Shareback** (GA) — providers can request consumer permission to share data back to the provider (or third parties) via governed exchange.
4. Snowflake Native Apps now support **Inter-App Communication** (Preview) — apps can securely communicate with other apps in the same consumer account.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview; tracks Snowflake Intelligence usage with credits + tokens; each row represents a call to an agent/toolchain. |
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview; tracks Cortex Agent usage with credits + tokens; each row represents a call to an agent/toolchain. |

## MVP Features Unlocked

1. **AI spend attribution dashboard (account-level):** join / aggregate these new usage-history views by user, warehouse, agent_id, request_id, time window → “who/what is burning AI credits” trend + top offenders.
2. **Budget guardrails for AI features:** detect spikes in Snowflake Intelligence / Cortex Agent credits and trigger alerts (email/Slack) or annotate “this agent version” as a regression.
3. **Native App telemetry pipeline (using Shareback):** for a FinOps Native App, request shareback permission so consumers can securely share aggregated usage/spend metrics back to the provider for benchmarking + product analytics.

## Concrete Artifacts

### Example rollup query (draft)

```sql
-- AI spend rollup by day + user (draft; validate actual column names in the views)
select
  date_trunc('day', start_time) as day,
  user_name,
  agent_id,
  sum(credits) as credits
from snowflake.account_usage.snowflake_intelligence_usage_history
where start_time >= dateadd('day', -30, current_timestamp())
group by 1,2,3
order by 1 desc, 4 desc;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Views are **Preview** and may change schema/retention | Breaking queries/dashboards | Confirm columns + retention in view docs; add schema-versioning checks in app. |
| Column names in draft SQL are guessed (`start_time`, `credits`, etc.) | Example query may not run | Pull the view definitions / docs and update SQL accordingly. |
| Shareback + inter-app comm require specific consumer permissions / app manifest changes | App workflow complexity | Prototype the permission flow and document prerequisites. |

## Links & Citations

1. Feb 18, 2026: Account Usage new `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
2. Feb 18, 2026: Account Usage new `CORTEX_AGENT_USAGE_HISTORY` view (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-cortex-agent-usage-history-view
3. Feb 10, 2026: Native Apps Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Feb 13, 2026: Native Apps Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac

## Next Steps / Follow-ups

- Fetch the full view docs to lock down exact column names + retention windows; update the SQL artifact into a tested query.
- Decide whether our FinOps app should ship “AI spend attribution” as a first-class module (these views make it easy).
- For Native Apps: sketch a provider/consumer architecture leveraging Shareback for telemetry and (optionally) inter-app comm for composable app ecosystems.
