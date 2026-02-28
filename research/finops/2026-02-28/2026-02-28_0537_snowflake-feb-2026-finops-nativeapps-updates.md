# Snowflake updates (FinOps + Native Apps) — Feb 2026 (watch)

- **When:** 2026-02-28 05:37 UTC
- **Why this note:** Cron “Snowflake Updates Watch (every 6h)” surfaced several release-note items that unlock FinOps workflows and Native App product surface.

## Executive summary
Notable items in recent Snowflake feature updates / server release notes:
- **Budgets: user-defined actions** (2026-02-24) — enables automated responses when budgets hit thresholds.
- **Billing: view invoices in Snowsight** (2026-02-24) — improves self-serve billing observability (good for FinOps workflows + app UX guidance).
- **Native Apps: Configuration (Preview)** (2026-02-20) — new configuration surface for apps; likely impacts how we ship customer-tunable settings.
- **Account Usage: new/GA AI usage views** (2026-02-25) — new ACCOUNT_USAGE views for Cortex Agent usage + Snowflake Intelligence usage; relevant for AI cost attribution.
- **Server release 10.6** (Feb 23–27, 2026) includes governance + Iceberg updates; the governance item matters for data quality ownership models.

## What changed (source-backed)
### 1) Budgets: User-defined actions (FinOps)
- Release note: “**User-defined actions for budgets**” (Feb 24, 2026).
- Why it matters:
  - We can build **closed-loop FinOps automation**: alert → execute action (notify Slack/Jira, pause non-prod warehouses, adjust resource monitors, etc.).
  - For a Native App, this is a strong integration point: “bring your own response function/action.”

### 2) Billing: View invoices in Snowsight
- Release note: “**View invoices in Snowsight**” (Feb 24, 2026).
- Why it matters:
  - Signals Snowflake is continuing to expand in-console billing visibility; we should align our app UX to complement (not duplicate) what Snowsight now shows.
  - Potentially reduces friction for invoice access, which is often a dependency for FinOps reporting.

### 3) Native Apps: Configuration (Preview)
- Release note: “**Snowflake Native Apps: Configuration (Preview)**” (Feb 20, 2026).
- Why it matters:
  - Likely adds an official pattern for **customer-configurable settings** (feature flags, thresholds, targets) without the “edit table / run SQL” dance.
  - If it includes UI hooks, could reduce custom UI work in our app.

### 4) New ACCOUNT_USAGE views for AI usage attribution
- Release notes (Feb 25, 2026):
  - **ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY** (GA)
  - **ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY** (GA)
- Why it matters:
  - First-class objects for **AI cost attribution**: track spend/usage by agent/feature over time.
  - Useful for “AI spend guardrails” in the FinOps app.

### 5) Server release 10.6 (Feb 23–27, 2026)
- Data governance update highlighted: “**Data quality: Non-owners can associate a data metric function with an object (GA)**”.
- Why it matters:
  - Impacts governance operating model: quality checks can be applied by non-owners → our app can propose/automate DMF association more broadly (with the right role).

## Snowflake objects & data sources (actionable)
- **ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY** (GA) — new view (per release note).
- **ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY** (GA) — new view (per release note).
- **Budgets** — feature surface; exact objects/APIs to drive actions are not specified in the overview page (needs follow-up read of the specific release note page).
- **Billing invoices in Snowsight** — UI feature; may correspond to internal billing tables but not required for our app.

## MVP features unlocked (PR-sized)
1) **Budget action → incident workflow**
   - Add a small “action runner” pattern: when a budget threshold event occurs, trigger a notification integration.
   - Start with: webhook → message; later: pause warehouses in tagged env.
2) **AI usage attribution dashboard**
   - Ingest the two new ACCOUNT_USAGE views and attribute spend by app/warehouse/user where possible.
   - Ship a basic UI: “Top agents by usage (7d/30d)”.
3) **Native App configuration surface**
   - Prototype a settings model for thresholds + alert routing that can move to the new Configuration feature if it fits.

## Risks / assumptions
- I have **not yet opened the individual release-note detail pages** for each item in this run; the overview list doesn’t include all implementation details.
- “User-defined actions for budgets” may require specific editions/roles or may have constraints (rate limits, supported action types).
- The new ACCOUNT_USAGE views may have typical ACCOUNT_USAGE latency (hours) which impacts “real-time” guardrails.

## Links
- Snowflake server release notes and feature updates: https://docs.snowflake.com/en/release-notes/new-features
- Feb 24, 2026: View invoices in Snowsight: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices
- Feb 24, 2026: User-defined actions for budgets: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
- Feb 20, 2026: Native Apps configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
- Feb 25, 2026: ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-cortex-agent-usage-history-view
- Feb 25, 2026: ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-25-snowflake-intelligence-usage-history-view
- 10.6 server release notes (Feb 23–27, 2026): https://docs.snowflake.com/en/release-notes/2026/10_6
