# FinOps Research Note — Warehouse budgets & resource monitor guardrails (Native App)

- **When (UTC):** 2026-02-01 21:04
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):**
  A FinOps Native App can deliver “guardrails” that are actionable (alerts + enforceable suspends) by composing Snowflake primitives:
  - **Budgets**: forecast-based daily notifications for monthly credit limits across warehouses *and* serverless/services.
  - **Resource monitors**: hard stop / suspend actions specifically for user-managed warehouses.
  The app can (a) inventory existing guardrails, (b) detect gaps/misconfigurations, (c) generate safe “recommended SQL” to implement, and (d) surface near-real-time spend risk with known latencies.

## Accurate takeaways
- **Resource monitors are warehouse-only cost controls**: they can monitor warehouse + associated cloud services credits, send notifications, and can suspend warehouses when thresholds are reached; they cannot track serverless/AI services (use budgets for those). [Snowflake Docs — Resource Monitors](https://docs.snowflake.com/en/user-guide/resource-monitors)
- **Budgets define a monthly spending limit (credits) and notify when projected to exceed**; notifications can go to emails, cloud queues (SNS/Event Grid/PubSub), or webhooks (Slack/Teams/PagerDuty, etc.). [Snowflake Docs — Budgets](https://docs.snowflake.com/en/user-guide/budgets)
- **Budgets operate on a calendar-month interval with UTC boundaries**, can backfill (with nuance), and have a *refresh interval* (default up to ~6.5h, optionally 1h “low latency” at higher compute cost). [Snowflake Docs — Budgets](https://docs.snowflake.com/en/user-guide/budgets)
- **ACCOUNT_USAGE.RESOURCE_MONITORS is (up to) 2 hours latent** and includes thresholds (NOTIFY/SUSPEND/SUSPEND_IMMEDIATE) and remaining credits, enabling a simple “monitor health” dashboard. [Snowflake Docs — ACCOUNT_USAGE.RESOURCE_MONITORS](https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors)
- **Budgets provide spend trendline + daily overspend notification mechanics** (how Snowflake computes the “spend limit line” and keeps notifying daily while overspend continues). [Snowflake Blog — Budgets](https://www.snowflake.com/en/blog/more-effective-spend-management-budgets/)

## Snowflake objects & data sources (verify in target account)
- **SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS**
  - Key columns: `NAME`, `CREDIT_QUOTA`, `USED_CREDITS`, `REMAINING_CREDITS`, `WAREHOUSES`, `NOTIFY`, `SUSPEND`, `SUSPEND_IMMEDIATE`, `LEVEL`.
  - Latency: up to 120 minutes. [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors)
- **Budgets** (class/objects/telemetry): docs describe product behavior + roles; specific system views for budgets were not confirmed in this pass.
  - Known from docs: budgets support multiple delivery integrations (email/webhook/queue) and can be configured with “low latency” refresh at additional cost. [Docs](https://docs.snowflake.com/en/user-guide/budgets)
- Likely supporting views for spend attribution:
  - `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` (budget docs reference it as the source for service-type availability in Account Usage). [Docs](https://docs.snowflake.com/en/user-guide/budgets)

## MVP features unlocked (PR-sized)
1) **Guardrails inventory dashboard (read-only):**
   - List all resource monitors, assigned warehouses, quota, thresholds, and “risk score” (e.g., % used).
   - Highlight warehouses with *no* monitor, or monitors with suspicious configuration (e.g., only NOTIFY, no SUSPEND).
2) **One-click SQL generator (copy/paste) for warehouse guardrails:**
   - Generate `CREATE RESOURCE MONITOR` + `ALTER WAREHOUSE ... SET RESOURCE_MONITOR = ...` recommendations.
   - Provide “safe defaults” (notify at 80%, suspend at 100%) with role/privilege caveats.
3) **Budget posture checker (configuration gap detection):**
   - Confirm whether budgets are activated/used, whether refresh interval is default vs low-latency (higher cost), and whether notifications are routed to an integration.

## Heuristics / detection logic (v1)
- **Warehouse without any resource monitor:**
  - From `ACCOUNT_USAGE.RESOURCE_MONITORS.WAREHOUSES` parse assigned names; compare to warehouse inventory list (to be sourced separately).
- **Monitor present but non-enforcing:**
  - `SUSPEND` and `SUSPEND_IMMEDIATE` are NULL/0 while `NOTIFY` is set → warn that the monitor only alerts.
- **Quota risk (simple):**
  - `used_pct = USED_CREDITS / CREDIT_QUOTA` (handle VARIANT types) and alert tiers at 70/85/95%.
- **Cadence / freshness warning:**
  - Always show “data freshness” badge: RESOURCE_MONITORS can be up to 2 hours delayed. [Docs](https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors)
  - Budgets have refresh interval up to ~6.5h by default; “low latency” 1h costs more. [Docs](https://docs.snowflake.com/en/user-guide/budgets)

## Concrete artifact — SQL draft (resource monitor health view)
> Goal: a single query the Native App can run (under the consumer role) to populate a “Resource Monitor Health” card.

```sql
-- Resource monitor health / posture (ACCOUNT_USAGE is up to 2h latent)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS
WITH rm AS (
  SELECT
    name,
    level,
    created,
    owner,
    warehouses,
    TRY_TO_DOUBLE(credit_quota)           AS credit_quota_credits,
    TRY_TO_DOUBLE(used_credits)           AS used_credits,
    remaining_credits,
    notify,
    suspend,
    suspend_immediate
  FROM snowflake.account_usage.resource_monitors
)
SELECT
  name,
  level,
  created,
  owner,
  warehouses,
  credit_quota_credits,
  used_credits,
  remaining_credits,
  IFF(credit_quota_credits > 0, used_credits / credit_quota_credits, NULL) AS used_pct,
  notify,
  suspend,
  suspend_immediate,
  /* Posture flags */
  IFF((suspend IS NULL OR suspend = 0) AND (suspend_immediate IS NULL OR suspend_immediate = 0), TRUE, FALSE) AS alerts_only,
  IFF(credit_quota_credits IS NULL OR credit_quota_credits = 0, TRUE, FALSE) AS missing_quota
FROM rm
ORDER BY used_pct DESC NULLS LAST, name;
```

## Security/RBAC notes
- Resource monitors: docs indicate only ACCOUNTADMIN can create, but privileges can be granted to other roles to view/modify monitors. [Docs](https://docs.snowflake.com/en/user-guide/resource-monitors)
- Budgets: docs mention **application roles** (BUDGET_VIEWER, BUDGET_ADMIN) and **instance roles** for custom budgets (VIEWER/ADMIN) to delegate management/visibility. [Docs](https://docs.snowflake.com/en/user-guide/budgets)
- For a Native App, prefer:
  - **Read-only posture** via ACCOUNT_USAGE views wherever possible.
  - **Actionability** via “generated SQL” the admin runs (avoid needing the app to hold elevated privileges).

## Risks / assumptions
- **Budgets telemetry/views**: this note does not confirm the exact ACCOUNT_USAGE / ORG_USAGE views for budgets state (activated, current spend, refresh interval) beyond what the docs describe; we should explicitly validate what is queryable vs UI-only.
- **Type handling**: `CREDIT_QUOTA` / `USED_CREDITS` are VARIANT in `ACCOUNT_USAGE.RESOURCE_MONITORS`; `TRY_TO_DOUBLE()` is a best-effort cast and should be tested.
- **Warehouse inventory source**: to detect “warehouses without monitors”, we need an authoritative warehouse list (e.g., `SHOW WAREHOUSES` output ingested into an app-owned table, or an appropriate ACCOUNT_USAGE view if available).

## Links / references
- https://docs.snowflake.com/en/user-guide/resource-monitors
- https://docs.snowflake.com/en/user-guide/budgets
- https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors
- https://www.snowflake.com/en/blog/more-effective-spend-management-budgets/
