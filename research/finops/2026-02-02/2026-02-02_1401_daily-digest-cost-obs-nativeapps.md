# FinOps Research Note — Cost attribution + guardrails + Native App observability hooks

- **When (UTC):** 2026-02-02 14:01
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** The Native App can ship an opinionated “cost control plane” that (a) attributes warehouse spend down to idle vs queries, (b) ties spend to teams via `QUERY_TAG`, and (c) provides safe guardrails (resource monitors/budgets) + app-level telemetry for support/ops.

## Accurate takeaways
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` provides **hourly** credit usage per warehouse for up to **365 days**, including compute vs cloud services credits; it also exposes **credits attributed to compute queries** (excludes idle). Latency can be **up to 3 hours** (and cloud services up to **6 hours**). It includes an example for computing **idle cost** as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)`.  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` includes `QUERY_TAG`, warehouse identifiers/names, execution + queue times, bytes scanned, and cloud services credits (with the caveat that adjustments can make “billed” lower than raw credits). This is the backbone for **per-query** explainability and for joining to higher-level warehouse metrics.  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
- Resource monitors are a first-class object that can **notify** and/or **suspend** user-managed warehouses when thresholds are reached, but they **do not** cover serverless features/AI services; Snowflake explicitly points to using a **budget** for those. Resets occur at **12:00 AM UTC** for the interval, and limits do not account for the daily cloud-services adjustment.  
  Source: https://docs.snowflake.com/en/user-guide/resource-monitors
- Snowflake’s logging/tracing/metrics features store telemetry in an **event table** with an OpenTelemetry-derived model; Snowflake notes there is a **default event table** that is “active by default,” and you control volume via **telemetry levels**.  
  Source: https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-overview
- For Snowflake Native Apps specifically, providers can configure apps to emit logs/traces/metrics and optionally enable **event sharing** from consumer → provider, but providers are responsible for provider-side **ingestion + storage costs**. The doc also calls out `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_STATE` (e.g., `LAST_HEALTH_STATUS`) as a way to monitor consumer app health.  
  Source: https://docs.snowflake.com/en/developer-guide/native-apps/event-about
- New (Preview) capability: consumers can set **maintenance policies** for Native App upgrades (delaying upgrades during specified windows). This impacts how we schedule/roll out cost-model changes or “guardrail” defaults without breaking customer ops windows.  
  Source: https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies

## Snowflake objects & data sources (verify in target account)
- **Cost / metering**
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly warehouse credits; has `CREDITS_USED_*` + `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`)  
    Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (query facts: timings, `QUERY_TAG`, bytes scanned, `WAREHOUSE_NAME`, `CREDITS_USED_CLOUD_SERVICES`, etc.)  
    Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
  - (Mentioned by Snowflake in metering docs) `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` for “billed” reconciliation when cloud services adjustment matters (not pulled today; cite via WAREHOUSE_METERING_HISTORY doc language).
- **Guardrails**
  - Resource monitor object(s) + their schedule/actions (not an ACCOUNT_USAGE view; you’ll likely introspect via `SHOW RESOURCE MONITORS` / `DESCRIBE RESOURCE MONITOR` in customer account).  
    Source: https://docs.snowflake.com/en/user-guide/resource-monitors
- **Native App operability**
  - `SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_STATE` for consumer health (`LAST_HEALTH_STATUS`, etc.).  
    Source: https://docs.snowflake.com/en/developer-guide/native-apps/event-about
  - Event table (default or custom) for logs/traces/metrics; volume controlled via telemetry levels.  
    Source: https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-overview

## Feature ideas (concrete; 5–10)
1) **Idle-cost leaderboard (per warehouse, per day/week)**: compute `idle_credits = credits_used_compute - credits_attributed_compute_queries` from `WAREHOUSE_METERING_HISTORY`, and rank warehouses by idle burn + % idle. Include “top idle hours” heatmap.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2) **Warehouse “true cost” vs “raw credits” reconciliation panel**: show the difference between raw cloud-services credits and “billed” credits by cross-referencing `METERING_DAILY_HISTORY` (called out in docs) and explain the adjustment caveat in UI.
3) **Query-tag cost attribution**: enforce/encourage `QUERY_TAG` usage and summarize spend by tag (team/app/env). Use `QUERY_HISTORY.QUERY_TAG` to build a daily rollup (with guardrails for NULL/empty tags).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
4) **Queue-time and overload cost insight**: flag warehouses with high `QUEUED_OVERLOAD_TIME`/`QUEUED_PROVISIONING_TIME` and correlate to spend spikes; recommend resizing vs multi-cluster changes.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
5) **Cloud-services “surprise” detector**: monitor `QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES` and alert when cloud services exceed a % of compute for a workload/warehouse/day, with docs-informed caveat about billed adjustments.
6) **Resource monitor coverage audit**: detect which warehouses are not assigned to a monitor (via `SHOW WAREHOUSES` + `SHOW RESOURCE MONITORS` outputs) and propose a standardized monitor policy set (dev/test/prod).  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors
7) **“Serverless + AI spend needs budgets” UX**: explicitly call out in the app that resource monitors don’t cover serverless/AI, and guide admins toward budgets for those categories (even if budget APIs aren’t integrated yet).  
   Source: https://docs.snowflake.com/en/user-guide/resource-monitors
8) **Native App supportability mode (telemetry levels)**: add a “Support Mode” toggle that asks the consumer to set higher telemetry levels temporarily, and logs to an event table; include expiration + reminders to reduce data volume.  
   Source: https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-overview
9) **Provider-side event sharing cost controls**: if event sharing is enabled, surface estimated ingestion/storage and recommend sampling/levels; make this an explicit “cost/benefit” choice for customers.  
   Source: https://docs.snowflake.com/en/developer-guide/native-apps/event-about
10) **Upgrade window awareness**: read/validate consumer maintenance policies (where possible) and schedule app-driven migrations/alerts accordingly; at minimum, document “upgrade blackout windows” behavior in the app’s admin UI.  
    Source: https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies

## MVP features unlocked (PR-sized)
1) **Idle cost daily rollup view + UI card**
   - Create a `FINOPS_IDLE_COST_DAILY` view/table in the app schema that aggregates the last N days from `WAREHOUSE_METERING_HISTORY` with:
     - `warehouse_name`, `usage_date`, `credits_used_compute`, `credits_attributed_compute_queries`, `idle_credits`, `idle_pct`
   - Add a single UI card: “Top 10 warehouses by idle credits (7d)” + sparkline.
   - Document expected data latency (3–6h) and that it’s based on Account Usage.

## Heuristics / detection logic (v1)
- **Idle burn (hourly):** `idle_credits_hour = credits_used_compute - credits_attributed_compute_queries` (clamp at 0 if needed).
- **Idle % (daily):** `SUM(idle_credits_hour) / NULLIF(SUM(credits_used_compute),0)`.
- **Potential over-provisioning signal:** high idle % + low bytes scanned/rows produced in `QUERY_HISTORY` for that warehouse’s workload window.
- **Queueing signal:** sustained `queued_overload_time` + rising spend → recommend multi-cluster or resizing.

## Security/RBAC notes
- The app should treat Account Usage views as **sensitive** (contains query text, usernames, role names in `QUERY_HISTORY`) and use least-privilege roles.
- If exposing query text in UI, consider redaction/opt-in, or store only derived aggregates.

## Risks / assumptions
- **Latency & completeness:** Account Usage views have known lag (up to hours). UI must communicate “data freshness” and avoid false alarms.
- **Attribution limits:** `WAREHOUSE_METERING_HISTORY` attributes compute credits to queries but explicitly excludes idle from that column; we must compute idle indirectly.
- **Event sharing cost:** provider is responsible for provider-side costs; “turn it on by default” could be a surprise bill.
- **Budgets integration:** resource monitors don’t cover serverless/AI; if we don’t integrate budgets, we still need a UX story.

## Links / references
- WAREHOUSE_METERING_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
- QUERY_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_history
- Resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
- Logging/tracing overview (event tables, telemetry levels): https://docs.snowflake.com/en/developer-guide/logging-tracing/logging-tracing-overview
- Native Apps logging + event sharing: https://docs.snowflake.com/en/developer-guide/native-apps/event-about
- Native Apps consumer maintenance policies (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
