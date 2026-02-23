# Research: Native Apps - 2026-02-23

**Time:** 1049 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Native Apps now support “application configurations” (Preview)** where an app defines configuration keys and consumers provide values (strings like URLs/account IDs, or names of other apps for inter-app comm). Config values can be marked **sensitive** to reduce exposure in query history / command output. (Feb 20, 2026) 
2. **Native Apps Inter-App Communication (Preview)** enables secure communication between apps in the same consumer account, aimed at sharing/merging data across multiple apps. (Feb 13, 2026)
3. **Native Apps Shareback is GA**: apps can request consumer permission to share data back to the provider or third parties (telemetry/analytics sharing, compliance reporting, preprocessing). (Feb 10, 2026)
4. For FinOps/observability of AI usage: `ACCOUNT_USAGE` added **`SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (Preview)** and **`CORTEX_AGENT_USAGE_HISTORY` (Preview)**, with per-request credits/tokens metadata (user/request/agent IDs). (Feb 18, 2026)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | Release notes (Feb 18, 2026) | Preview; per-call tokens + credits; includes request + agent metadata. |
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | Release notes (Feb 18, 2026) | Preview; per-call tokens + credits; includes request + agent metadata. |
| Native App **application configuration** | Capability | Release notes (Feb 20, 2026) | Preview; consumer-provided config keys; sensitive values to avoid exposure. |
| Native App **inter-app communication** | Capability | Release notes (Feb 13, 2026) | Preview; apps securely communicate in same account. |
| Native App **shareback** | Capability | Release notes (Feb 10, 2026) | GA; governed permissioned data sharing back to provider/3rd parties. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App “provider telemetry” that doesn’t require manual secrets**: use *application configurations* for consumer-provided endpoints/IDs (mark sensitive), and pair with **Shareback GA** for permissioned telemetry export back to provider.
2. **Cross-app FinOps workflows** (Preview-dependent): integrate with customer’s other in-account apps (e.g., their “platform governance” app) via inter-app communication to enrich cost insights with org metadata.
3. **AI spend attribution dashboards**: ingest `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` + `CORTEX_AGENT_USAGE_HISTORY` into app tables for per-user/per-agent cost, anomaly detection, and budgets/alerts.

## Concrete Artifacts

### SQL starter: AI usage cost attribution (ACCOUNT_USAGE)

```sql
-- Preview views: confirm availability/columns in target account.
-- Goal: per-day credit burn by user + agent.

select
  date_trunc('day', start_time) as day,
  user_name,
  agent_id,
  sum(credits) as credits
from snowflake.account_usage.cortex_agent_usage_history
group by 1,2,3
order by 1 desc, 4 desc;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview features/objects may not be enabled in all accounts/regions immediately. | Queries/features may fail for some customers. | Add capability detection + graceful fallbacks; test across editions/regions. |
| Exact column names/types for the new usage history views may differ from expectations. | Attribution SQL may need updates. | Inspect `DESC VIEW`/docs for column list; adjust ingestion schema. |
| “Sensitive” configs reduce exposure but may still have operational caveats (e.g., role access, auditing). | Secrets handling could be misunderstood. | Review “Application configuration” docs and confirm behavior in query history. |

## Links & Citations

1. Snowflake server release notes & feature updates (includes links to each item): https://docs.snowflake.com/en/release-notes/new-features
2. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
3. Native Apps: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
5. `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view (Preview) (Feb 18, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
6. `CORTEX_AGENT_USAGE_HISTORY` view (Preview) (Feb 18, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-cortex-agent-usage-history-view

## Next Steps / Follow-ups

- Pull the full column list for both preview usage views and draft ingestion DDL + dbt model (or Snowpark pipeline) for the FinOps app.
- Review “Application configuration” docs to understand lifecycle (defaults, updates, access controls) and whether configs can be required/validated.
- Decide whether to gate inter-app communication as an optional integration (feature flag + docs).
