# Research: FinOps - 2026-02-27

**Time:** 09:36 UTC  
**Topic:** Org-level credit metering primitives for FinOps (and what a Native App can realistically automate)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage at the **organization** level (includes `ORGANIZATION_NAME`, `ACCOUNT_NAME`, `ACCOUNT_LOCATOR`, `REGION`) and is retained for **365 days** with up to **~120 minutes** latency.  
   Source: https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credit usage at the **account** level and is retained for **365 days** with up to **~180 minutes** latency.  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. Snowflake docs explicitly call out that to reconcile Account Usage cost data with corresponding Organization Usage data, you should set the session timezone to **UTC** before querying the Account Usage view (`ALTER SESSION SET TIMEZONE = UTC;`).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
4. Organization Usage access is privileged:
   - In the **organization account**, access is granted by `GLOBALORGADMIN`, and you can grant *application roles* in the SNOWFLAKE application (example uses `SNOWFLAKE.ORG_USAGE_ADMIN`).  
   - In an **ORGADMIN-enabled account**, access is controlled via **SNOWFLAKE database roles** like `ORGANIZATION_USAGE_VIEWER` / `ORGANIZATION_BILLING_VIEWER` / `ORGANIZATION_ACCOUNTS_VIEWER`.  
   Source: https://docs.snowflake.com/en/sql-reference/organization-usage
5. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage and includes additional attribution-ish columns such as `ENTITY_ID`, `ENTITY_TYPE`, `NAME`, plus optional `DATABASE_NAME`/`SCHEMA_NAME` where applicable; latency varies (generally up to ~180 minutes; some columns longer).  
   Source: https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Daily credits; includes `ACCOUNT_LOCATOR`, `ACCOUNT_NAME`, `REGION`; `USAGE_DATE` is explicitly UTC. Latency up to ~2h. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits (account only). Latency up to ~3h. Must set session timezone to UTC to reconcile to org usage. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits; has `ENTITY_*` + `NAME` + optional `DATABASE_NAME`/`SCHEMA_NAME` depending on `SERVICE_TYPE`. |
| `ALTER SESSION SET TIMEZONE = UTC` | Session setting | n/a | Required step (per docs) for reconciling Account Usage metering to Organization Usage metering. |
| Org usage access roles (`SNOWFLAKE.ORG_USAGE_ADMIN`, `SNOWFLAKE.ORGANIZATION_USAGE_VIEWER`, etc.) | Privileges / roles | n/a | Determines whether a given deployment can read org-wide metering inside a Native App installation context. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org vs account metering adapter (SQL views):** ship a minimal “metering normalization layer” that can operate in *either* mode:
   - Org mode: read `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` (if available)
   - Account mode: fall back to `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY`
2. **Timezone reconciliation guardrail:** automatically run/require `ALTER SESSION SET TIMEZONE = UTC;` in every ingestion/query path that compares org usage to account usage (prevents subtle day-boundary mismatches).
3. **Service-type drilldowns from hourly metering:** add a “top service types by credits (hourly)” view backed by `ACCOUNT_USAGE.METERING_HISTORY` for investigations (e.g., identify `SNOWPARK_CONTAINER_SERVICES`, `SERVERLESS_TASK`, etc. drivers).

## Concrete Artifacts

### SQL draft: Normalize daily credit metering (ORG_USAGE-first, ACCOUNT_USAGE fallback)

Goal: produce a single daily table/view that downstream app logic can consume without caring whether org-level access exists.

```sql
-- FINOPS.MART.DAILY_CREDITS_V
-- NOTE: This is a pattern draft. You’ll likely implement it as two views + a UNION ALL
-- controlled by a config flag because view compilation can fail if ORG_USAGE objects
-- aren’t accessible in the current account/role.

-- When reconciling account usage vs org usage, Snowflake docs recommend UTC.
ALTER SESSION SET TIMEZONE = UTC;

-- Option A: Org mode (preferred when available)
CREATE OR REPLACE VIEW FINOPS.MART.DAILY_CREDITS_ORG_V AS
SELECT
  organization_name,
  account_locator,
  account_name,
  region,
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_adjustment_cloud_services,
  credits_billed,
  'ORG_USAGE' AS source
FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY;

-- Option B: Account mode fallback
-- (No org/account columns; represent as NULLs and fill account metadata elsewhere.)
CREATE OR REPLACE VIEW FINOPS.MART.DAILY_CREDITS_ACCOUNT_V AS
SELECT
  NULL::VARCHAR  AS organization_name,
  NULL::VARCHAR  AS account_locator,
  CURRENT_ACCOUNT() AS account_name,
  NULL::VARCHAR  AS region,
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_adjustment_cloud_services,
  credits_billed,
  'ACCOUNT_USAGE' AS source
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY;
```

Implementation note (Native App reality): in many installs, referencing `SNOWFLAKE.ORGANIZATION_USAGE.*` may be impossible due to lack of org roles. Prefer a config-driven selection (or dynamic SQL in a stored procedure) so the app can compile in account-only environments.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Native App installation role may not have privileges to read `SNOWFLAKE.ORGANIZATION_USAGE` views (requires org-level roles / database roles). | Org-level rollups and multi-account chargeback features might not be available in many customer environments. | Validate with Native App privilege model + a test install in a non-org-admin account; document required grants and provide “account-only mode”. |
| Day boundary mismatches when comparing ORG_USAGE vs ACCOUNT_USAGE without timezone normalization. | Incorrect daily deltas, false anomalies, broken reconciliation. | Always set session TZ to UTC (explicitly recommended in docs) before ACCOUNT_USAGE queries used for reconciliation. |
| Relying on `SELECT *` on usage views risks breakage if Snowflake changes view columns. | App breakage on Snowflake upgrades. | Follow docs guidance: select only required columns (explicitly called out in both ACCOUNT_USAGE and ORGANIZATION_USAGE docs). |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history
2. https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
3. https://docs.snowflake.com/en/sql-reference/organization-usage
4. https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

## Next Steps / Follow-ups

- Research: what Native App roles/privileges are realistically grantable to allow reading `SNOWFLAKE.ORGANIZATION_USAGE` (and whether customers will do it).
- Add: a small “capability detection” routine (attempt a harmless `SELECT 1` from ORG_USAGE metering) to determine whether to enable org-mode features.
- Extend attribution: map hourly `ACCOUNT_USAGE.METERING_HISTORY` `SERVICE_TYPE` + `ENTITY_TYPE` to UI categories for investigations (warehouse vs serverless vs SCS vs replication vs search optimization).
