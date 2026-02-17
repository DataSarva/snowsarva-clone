# Research: Native Apps - 2026-02-17

**Time:** 15:45 UTC  
**Topic:** Snowflake Native App Framework + FinOps telemetry surfaces  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps now support **Inter-App Communication (IAC)** (Preview, open to all accounts), enabling one Native App to call another app’s functions/procedures in the same consumer account via a managed connection + approval workflow (client/server apps). [3]
2. IAC setup involves (a) **configuration definitions** to discover the target server app name, (b) **application specifications** to request a connection + server app roles, and (c) consumer approval, which triggers lifecycle callbacks on both client and server apps. [3]
3. Snowflake added **new ORGANIZATION_USAGE premium views** (rolled out by Feb 9, 2026) including hourly org-wide credit metering and a query-level cost attribution history view for warehouses. [1]
4. Snowflake released **listing/share observability** (GA) with new INFORMATION_SCHEMA views/table functions and new ACCOUNT_USAGE views + ACCESS_HISTORY enhancements to audit listing/share lifecycle DDL. [2]

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Native Apps Inter-App Communication (IAC) | Feature / API surface | Snowflake docs | Uses CONFIGURATIONS + SPECIFICATIONS + callbacks for connection lifecycle. [3] |
| ORGANIZATION_USAGE.METERING_HISTORY | View | ORG_USAGE (premium) | Hourly credit usage per account in org. [1] |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ORG_USAGE (premium) | Attributes warehouse compute costs to specific queries (org-wide). [1] |
| INFORMATION_SCHEMA.LISTINGS | View | INFO_SCHEMA | Provider-facing, real-time (no latency), does not capture deleted objects. [2] |
| INFORMATION_SCHEMA.SHARES | View | INFO_SCHEMA | Provider+consumer; consistent with SHOW SHARES. [2] |
| INFORMATION_SCHEMA.AVAILABLE_LISTINGS() | Table function | INFO_SCHEMA | Consumer discovery; supports filters (e.g., imported listings). [2] |
| ACCOUNT_USAGE.LISTINGS | View | ACCOUNT_USAGE | Historical listings; includes dropped objects; up to ~3h latency. [2] |
| ACCOUNT_USAGE.SHARES | View | ACCOUNT_USAGE | Historical shares; includes dropped objects. [2] |
| ACCOUNT_USAGE.GRANTS_TO_SHARES | View | ACCOUNT_USAGE | Historical grants/revokes to shares. [2] |
| ACCOUNT_USAGE.ACCESS_HISTORY | View | ACCOUNT_USAGE | Now captures listing/share CREATE/ALTER/DROP with detailed property changes in OBJECT_MODIFIED_BY_DDL JSON. [2] |

## MVP Features Unlocked

1. **App-to-app integrations:** Implement “provider plugin” architecture where Mission Control (FinOps app) can connect to and call other Native Apps (e.g., tagging/CMDB resolver, org policy app) via IAC instead of external APIs.
2. **Org-wide cost attribution module:** Add an optional “Org Mode” in the app that, when installed in the org account, uses ORG_USAGE.METERING_HISTORY + ORG_USAGE.QUERY_ATTRIBUTION_HISTORY to compute cross-account spend, hot warehouses, and top-cost queries.
3. **Marketplace/listing observability dashboard:** For teams distributing the app via listings, add a provider console section powered by INFORMATION_SCHEMA.LISTINGS/SHARES (real-time) and ACCOUNT_USAGE.* (historical) plus ACCESS_HISTORY audit trails.

## Concrete Artifacts

### IAC handshake skeleton (SQL)

```sql
-- (Consumer) discover incoming configuration requests on the server app
SHOW CONFIGURATIONS IN APPLICATION <server_app>;

-- (Consumer) set the server app name into the client app's configuration
ALTER APPLICATION <client_app>
  SET CONFIGURATION <server_app_configuration>
  VALUE = <SERVER_APP_NAME>;

-- (Client app) request connection to the server app via an application specification
ALTER APPLICATION SET SPECIFICATION <connection_spec>
  TYPE = CONNECTION
  LABEL = 'Server App'
  DESCRIPTION = 'Request for server app procedures/functions'
  SERVER_APPLICATION = <SERVER_APP_NAME>
  SERVER_APPLICATION_ROLES = ( <server_app_role> );

-- (Consumer) approve request on the server app
ALTER APPLICATION <server_app>
  APPROVE SPECIFICATION <connection_spec>
  SEQUENCE_NUMBER = 1;
```

### Listing/share observability quick checks (SQL)

```sql
-- Provider real-time inventory (no latency)
SELECT * FROM <db>.INFORMATION_SCHEMA.LISTINGS;
SELECT * FROM <db>.INFORMATION_SCHEMA.SHARES;

-- Consumer discovery
SELECT * FROM TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS());
SELECT * FROM TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS(IS_IMPORTED => TRUE));
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ORG_USAGE premium views rollout/availability varies by org account and entitlement. | Org-wide features may not work everywhere; need graceful fallback to ACCOUNT_USAGE. | Confirm view presence + permissions at install time; document prerequisites. [1] |
| IAC is Preview; semantics/SQL surface may change. | App-to-app integration could require refactors later. | Track IAC release notes; build a thin abstraction layer around IAC calls. [3] |
| Listing/share observability views have different latency and deletion semantics (INFO_SCHEMA vs ACCOUNT_USAGE). | Dashboards may disagree across “real-time” and “historical” pages. | Label data freshness in UI and reconcile by timestamp windows. [2] |

## Links & Citations

1. New ORGANIZATION_USAGE premium views (Feb 01, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
2. Listing/share observability GA (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga
3. Inter-app communication docs (Preview, updated Feb 2026): https://docs.snowflake.com/en/developer-guide/native-apps/inter-app-communication

## Next Steps / Follow-ups

- Pull and summarize the exact column sets for ORG_USAGE.QUERY_ATTRIBUTION_HISTORY and ORG_USAGE.METERING_HISTORY (for schema mapping + UI tables).
- Evaluate whether IAC can be used to securely exchange cost signals between apps without external egress (design: synchronous proc calls vs async tables).
- Add an “observability for distribution” section to the Mission Control roadmap (listing lifecycle audit + share tracking).
