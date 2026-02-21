# Research: Native Apps - 2026-02-21

**Time:** 10:20 UTC  
**Topic:** Snowflake Native App Framework (+ FinOps-adjacent telemetry views)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Shareback is GA (Feb 10, 2026):** Snowflake Native Apps can request permission from consumers to share data back to the provider or designated third parties via app specifications, enabling governed telemetry / compliance reporting patterns. [1]
2. **Inter-app communication is Preview (Feb 13, 2026):** Native apps can securely communicate with other apps in the same consumer account, enabling data sharing/merging between apps. [2]
3. **Application configuration is Preview (Feb 20, 2026):** Native apps can request configuration values from consumers (including sensitive values) via “application configurations”; sensitive configs are protected from exposure in query history and command output. [3]
4. **New usage telemetry views (Preview, Feb 18, 2026):**
   - `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` provides credits/tokens + metadata per Cortex Agent call. [4]
   - `ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` provides credits/tokens + metadata per Snowflake Intelligence interaction/call. [5]
5. **Marketplace/provider observability is GA (Feb 02, 2026):** Snowflake added real-time Information Schema views and historical Account Usage views for listings/shares, and expanded `ACCOUNT_USAGE.ACCESS_HISTORY` to capture listing/share DDL operations. [6]
6. **Org-level FinOps views (Premium, Feb 01, 2026):** `ORGANIZATION_USAGE.METERING_HISTORY` and `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (premium views) provide org-wide credit usage and query-level cost attribution (rollout completed by Feb 9, 2026). [7]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---:|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview; credits/tokens/metadata per agent call. [4] |
| `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | View | `ACCOUNT_USAGE` | Preview; credits/tokens/metadata per Snowflake Intelligence interaction/call. [5] |
| `<db>.INFORMATION_SCHEMA.LISTINGS` | View | `INFO_SCHEMA` | GA; real-time; provider-focused; no deleted objects. [6] |
| `<db>.INFORMATION_SCHEMA.SHARES` | View | `INFO_SCHEMA` | GA; real-time; inbound + outbound; consistent with `SHOW SHARES`. [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.LISTINGS` | View | `ACCOUNT_USAGE` | GA; historical; includes dropped listings. [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.SHARES` | View | `ACCOUNT_USAGE` | GA; historical; includes dropped shares. [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES` | View | `ACCOUNT_USAGE` | GA; historical grant/revoke operations. [6] |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | View | `ACCOUNT_USAGE` | Now includes listing/share DDL + property changes in `OBJECT_MODIFIED_BY_DDL`. [6] |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY` | View | `ORG_USAGE` | Premium; hourly credits per account. [7] |
| `SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ORG_USAGE` | Premium; attributes warehouse compute cost to queries. [7] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Provider telemetry pipeline via Shareback (GA):** add an in-app “opt-in telemetry” path that writes aggregated cost/health metrics into a shareback-approved table/share back to provider (or a 3rd-party “telemetry sink” account). This unblocks real usage analytics without requiring outbound network egress. [1]
2. **Multi-app “suite” integration via Inter-app Communication (Preview):** enable a FinOps app to interoperate with an Observability/Governance app in the same consumer account (e.g., share anomaly alerts + attribution metadata), without external services. [2]
3. **Secure consumer-provided configuration (Preview):** request a per-consumer `TELEMETRY_TARGET_ACCOUNT`, `SERVER_APP_NAME`, or an external URL token as an app configuration; mark sensitive config for safe handling (avoids leaking secrets via query history). [3]

## Concrete Artifacts

### Draft: “AI Spend Telemetry” query surfaces (preview views)

```sql
-- Cortex Agents / Snowflake Intelligence cost telemetry (Preview views)
-- NOTE: column set may evolve; avoid SELECT * in production.

-- Cortex Agents
SELECT
  start_time,
  end_time,
  user_name,
  request_id,
  agent_id,
  credits
FROM snowflake.account_usage.cortex_agent_usage_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY start_time DESC;

-- Snowflake Intelligence
SELECT
  start_time,
  end_time,
  user_name,
  request_id,
  snowflake_intelligence_id,
  agent_id,
  credits
FROM snowflake.account_usage.snowflake_intelligence_usage_history
WHERE start_time >= dateadd('day', -7, current_timestamp())
ORDER BY start_time DESC;
```

### Draft: listing/share observability for providers (GA)

```sql
-- Real-time provider listing inventory (per-db)
SELECT *
FROM <db>.information_schema.listings;

-- Historical share grant/revoke audit
SELECT
  granted_on,
  name,
  grantee_name,
  privilege,
  granted_by,
  created_on,
  deleted_on
FROM snowflake.account_usage.grants_to_shares
WHERE created_on >= dateadd('day', -30, current_timestamp());
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Preview features/APIs may change (IAC, configuration, usage views). | Schema/behavior drift could break queries/app UX. | Gate behind feature flags; keep compatibility layer; monitor release notes weekly. |
| “Sensitive configuration” protection specifics (where exactly it is redacted) may have edge cases. | Secret leakage risk if misused. | Validate via controlled tests; confirm redaction in query history + SHOW output in a sandbox account. |
| Shareback adoption requires explicit consumer opt-in and governance approvals. | Telemetry might be unavailable for some customers. | Provide “local-only” mode; design for graceful degradation. |

## Links & Citations

1. Shareback (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Inter-app Communication (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
3. Application Configuration (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. `CORTEX_AGENT_USAGE_HISTORY` (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-cortex-agent-usage-history-view
5. `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` (Preview) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-18-snowflake-intelligence-usage-history-view
6. Listing/share observability (GA) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga
7. Org premium views (METERING_HISTORY, QUERY_ATTRIBUTION_HISTORY) — https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views

## Next Steps / Follow-ups

- Prototype a Native App “consumer configuration” flow for: (a) telemetry opt-in, (b) target account/app name for inter-app comm.
- Add a FinOps module that can read the new AI spend telemetry views when present, but falls back gracefully.
- Decide where to store per-consumer configuration in-app vs config objects (esp. secrets).