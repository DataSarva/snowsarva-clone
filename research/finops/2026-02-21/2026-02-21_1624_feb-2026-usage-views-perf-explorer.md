# Research: FinOps - 2026-02-21

**Time:** 1624 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake added a new `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (**Preview**) that provides per-interaction credit usage visibility for **Snowflake Intelligence**. Rows represent calls to an agent, including aggregated tokens/credits + metadata like `USER_ID`, `REQUEST_ID`, `SNOWFLAKE_INTELLIGENCE_ID`, `AGENT_ID`.
2. Performance Explorer received enhancements (**Preview**) that improve root-cause workflows: a “By grouped queries” tab to identify recurring queries driving metrics, hour-based filtering, interactive time-window selection via dragging on charts, and “PREVIOUS PERIOD” comparisons.
3. Together, these enable tighter **AI cost governance** (credits/tokens attribution for AI interactions) and faster **workload cost spike triage** (recurring queries + before/after comparisons) inside native Snowflake tooling.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | `ACCOUNT_USAGE` view | Snowflake release notes + docs | Preview. View includes agent/tool call details with credits/tokens. |
| Performance Explorer UI metrics + “grouped queries” breakdown | Snowsight feature | Snowflake release notes | Preview; not a queryable view (UI-driven), but can inform query-level follow-ups. |

## MVP Features Unlocked

1. **AI cost dashboard (Snowflake Intelligence):** ingest `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` to show credits/tokens by user, agent_id, request_id, and time; add guardrails/alerts when spend crosses thresholds.
2. **AI spend attribution joins:** link AI request IDs (if exposed) to internal chargeback entities (team/app/project) via session context tags or user mapping.
3. **Cost spike investigator workflow:** for a time window, use Performance Explorer to identify recurring/high-impact queries → deep-link into query history and produce automated “top drivers” reports.

## Concrete Artifacts

### Starter SQL: daily credits by user (Snowflake Intelligence)

```sql
-- Preview object; validate column names in docs before production use.
select
  date_trunc('day', start_time) as day,
  user_id,
  sum(credits) as credits
from snowflake.account_usage.snowflake_intelligence_usage_history
group by 1,2
order by 1 desc, 3 desc;
```

> Follow-up: confirm actual timestamp/credit column names from the view reference page.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| View is Preview and schema/semantics may change | Breaking dashboards | Version-pin semantics in semantic layer; add defensive parsing + monitoring. |
| Column names/types not captured in release note | SQL draft may be wrong | Pull the view reference page and update the SQL with exact fields. |
| Performance Explorer enhancements are UI-only | Limited automation | Use it for analyst workflow + deep links; pair with query history views for automation. |

## Links & Citations

1. Feb 18, 2026 — New `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
2. View reference: https://docs.snowflake.com/en/sql-reference/account-usage/snowflake_intelligence_usage_history_view
3. Feb 09, 2026 — Performance Explorer enhancements (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview
4. Performance Explorer guide: https://docs.snowflake.com/en/user-guide/performance-explorer

## Next Steps / Follow-ups

- Fetch the view reference page and lock down exact columns + join keys.
- Decide if we should materialize a derived table for AI usage (daily rollups + attribution dimensions) to stabilize Preview volatility.
- Add a “finops playbook” doc section: how to use Performance Explorer grouped queries + previous period to investigate sudden credit spikes.
