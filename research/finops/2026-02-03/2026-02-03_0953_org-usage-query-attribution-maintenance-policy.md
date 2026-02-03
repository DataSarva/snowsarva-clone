# FinOps Research Note — ORG_USAGE premium views + query-level cost attribution (and Native App upgrade maintenance policies)

- **When (UTC):** 2026-02-03 09:53
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):**
  - **FinOps:** Snowflake just introduced new **ORGANIZATION_USAGE premium views**, including **QUERY_ATTRIBUTION_HISTORY** (org-wide) and **METERING_HISTORY** (hourly credits by account). This materially improves **cross-account cost attribution** and enables org-level chargeback/showback without per-account data plumbing.
  - **Native Apps (preview):** Consumers can now **delay/schedule Native App upgrades** via *maintenance policies*, reducing upgrade disruption risk and enabling “safe rollout windows” for app releases.

## Accurate takeaways
- **New ORG_USAGE premium views (rolling out through Feb 9, 2026):**
  - `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` → hourly credits by account (service types include warehouses, serverless, SPCS, etc.).
  - `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` → attributes **compute credits to individual queries** across all accounts in an org.
  - `SNOWFLAKE.ORGANIZATION_USAGE.NETWORK_POLICIES` → org-wide network policy visibility (governance/security relevant).
- **QUERY_ATTRIBUTION_HISTORY details (org-level):**
  - Has `CREDITS_ATTRIBUTED_COMPUTE` (query execution only, excludes idle) and `CREDITS_USED_QUERY_ACCELERATION` (QAS) → total accelerated query cost = sum of the two.
  - Latency can be **up to 24 hours**.
- **Native Apps consumer-controlled maintenance policies (public preview):**
  - Consumers can create a `MAINTENANCE POLICY` (cron schedule with *start time* only) and apply it via `ALTER ACCOUNT ... FOR ALL APPLICATIONS` or `ALTER APPLICATION ...`.
  - Only **one** maintenance policy can be set per app or per account.
  - Provider can set a **maintenance deadline** so consumers can’t postpone indefinitely.

## Snowflake objects & data sources (verify in target account)
- **ORG_USAGE (premium):**
  - `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` (hourly credits; latency ≤ 24h)
  - `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (query-level compute attribution; latency ≤ 24h)
  - `SNOWFLAKE.ORGANIZATION_USAGE.NETWORK_POLICIES`
- Key columns to plan around:
  - `QUERY_ATTRIBUTION_HISTORY`: `ACCOUNT_LOCATOR`, `ACCOUNT_NAME`, `WAREHOUSE_NAME`, `QUERY_TAG`, `USER_NAME`, `START_TIME`, `END_TIME`, `CREDITS_ATTRIBUTED_COMPUTE`, `CREDITS_USED_QUERY_ACCELERATION`, `QUERY_HASH`, `QUERY_PARAMETERIZED_HASH`
  - `METERING_HISTORY`: `ACCOUNT_LOCATOR`, `ACCOUNT_NAME`, `SERVICE_TYPE`, `ENTITY_TYPE`, `NAME`, `CREDITS_USED_COMPUTE`, `CREDITS_USED_CLOUD_SERVICES`, `CREDITS_USED`

## MVP features unlocked (PR-sized)
1) **Org-level “Top expensive queries” leaderboard**
   - Backed by `ORG_USAGE.QUERY_ATTRIBUTION_HISTORY`, group by (`ACCOUNT_NAME`, `WAREHOUSE_NAME`, `QUERY_PARAMETERIZED_HASH`) with daily rollups.
2) **Chargeback by query_tag across all accounts**
   - Enforce/encourage `QUERY_TAG` conventions; show $ attribution by tag → team/app cost visibility.
3) **Cross-account anomaly detection with stronger priors**
   - Use `ORG_USAGE.METERING_HISTORY` as the org-wide baseline; detect per-account/service spikes and then drill down via `QUERY_ATTRIBUTION_HISTORY`.
4) **Native App release guidance: “set your maintenance policy before upgrading”**
   - Add an in-app checklist/UX copy that points consumers to `CREATE/ALTER MAINTENANCE POLICY` flows before applying new releases.

## Heuristics / detection logic (v1)
- **Daily expensive query detection:**
  - Filter last N days; compute `credits = CREDITS_ATTRIBUTED_COMPUTE + coalesce(CREDITS_USED_QUERY_ACCELERATION,0)`.
  - Rank within (`ACCOUNT_LOCATOR`, `WAREHOUSE_NAME`) and org-wide.
- **Tag hygiene score:**
  - `% of credits with non-null QUERY_TAG` per account/warehouse; alert if below threshold.
- **Org baseline anomaly:**
  - From `METERING_HISTORY`, compute z-score or robust median absolute deviation per (`ACCOUNT_LOCATOR`, `SERVICE_TYPE`) by hour-of-week.

## Security/RBAC notes
- These are **ORGANIZATION_USAGE premium views**: availability and access require an **organization account** and premium view access.
- View latency (≤24h) means this is **FinOps/ops**, not real-time guardrails.

## Risks / assumptions
- Rollout note says availability “by Feb 9, 2026” → some orgs may not see these views yet.
- Query attribution excludes warehouse idle time; total warehouse cost attribution still requires separate logic to allocate idle.
- Native Apps maintenance policies are **preview**; semantics/limits may change.

## Links / references
- Release note: New ORG_USAGE premium views (Feb 1, 2026)
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
- ORG_USAGE view docs:
  - QUERY_ATTRIBUTION_HISTORY: https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history
  - METERING_HISTORY: https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history
- Release note: Consumer-controlled maintenance policies for Snowflake Native Apps (Preview) (Jan 23, 2026)
  - https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
- Native Apps guide: Consumer-controlled maintenance policies
  - https://docs.snowflake.com/en/developer-guide/native-apps/consumer-maintenance-policies
