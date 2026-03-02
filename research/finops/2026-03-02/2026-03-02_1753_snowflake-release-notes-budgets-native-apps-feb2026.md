# Research: FinOps - 2026-03-02

**Time:** 1753 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake budgets can now trigger **user-defined actions** by automatically calling a **stored procedure** when a spending threshold is reached (based on *projected* or *actual* credit consumption), with up to **10 custom actions per budget**. *(Release note dated Feb 24, 2026.)*
2. Budgets can also call a stored procedure at **cycle start** (monthly restart), enabling “undo” automations (e.g., re-enable warehouses) for actions taken in the prior cycle. *(Release note dated Feb 24, 2026.)*
3. Snowflake **ORGANIZATION_USAGE premium views** now include **METERING_HISTORY** (hourly credit usage per account) and **QUERY_ATTRIBUTION_HISTORY** (attributes compute costs to specific queries run on warehouses across the org). *(Release note dated Feb 1, 2026.)*
4. Snowflake Native Apps added: **Shareback** (GA) to request permission to share data back to provider/third parties (Feb 10, 2026), **Inter-App Communication** (Preview) for secure app↔app communication in the same account (Feb 13, 2026), and **Application Configuration** (Preview) to request configuration values from consumers with an option to mark values as **sensitive** (Feb 20, 2026).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budget custom actions (stored procedure callback) | Feature | Snowflake release notes | Enables direct automation on threshold + cycle restart; implementation details in budget docs. |
| ORGANIZATION_USAGE.METERING_HISTORY | ORG_USAGE | Snowflake release notes | Hourly credit usage for each account in the org (premium view; availability/entitlement applies). |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | ORG_USAGE | Snowflake release notes | Org-wide query-level compute attribution for warehouse queries (premium view). |
| Native App “application configurations” | Feature | Snowflake release notes | Consumer-provided key/value config; can be marked sensitive to reduce exposure. |
| Native App shareback | Feature | Snowflake release notes | Governed channel to send data back to provider/3rd party upon consumer permission. |
| Native App inter-app communication | Feature | Snowflake release notes | Secure communication between native apps in same consumer account (preview). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Budget-action automation pack (FinOps guardrails):** ship a reference stored procedure that budgets can call on threshold breach to (a) suspend/resize specific warehouses, (b) tag the event in a log table, and (c) emit a standardized notification.
2. **“Cycle reset” autopilot:** ship a paired stored procedure for cycle-start actions to reverse guardrail actions (re-enable warehouses, reset resource monitors, post monthly summary).
3. **Org-wide cost attribution dashboards:** use `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` + `METERING_HISTORY` to build: “top expensive queries across the org,” “cost by account/team,” and “anomaly spikes by account hour.”
4. **Native App secure setup UX (Preview config):** implement consumer onboarding that requests required config keys (e.g., external URL/account identifiers) and marks secrets as sensitive; reduces copy/paste sprawl.
5. **Native App telemetry/FinOps loop via shareback (GA):** implement opt-in “shareback” of aggregated usage signals back to provider for benchmarking + recommendations.

## Concrete Artifacts

### Budget action stored procedure (skeleton)

```sql
-- Pseudocode-ish: exact signature/handler depends on Snowflake budget custom actions contract.
-- Goal: one proc can be re-used across many budgets with a small config table.

CREATE OR REPLACE TABLE FINOPS.BUDGET_ACTION_LOG (
  ts TIMESTAMP_LTZ,
  budget_name STRING,
  action STRING,
  threshold_pct NUMBER(5,2),
  basis STRING, -- PROJECTED or ACTUAL
  details VARIANT
);

CREATE OR REPLACE PROCEDURE FINOPS.ON_BUDGET_THRESHOLD(
  BUDGET_NAME STRING,
  THRESHOLD_PCT NUMBER(5,2),
  BASIS STRING,
  DETAILS VARIANT
)
RETURNS STRING
LANGUAGE SQL
AS
$$
  INSERT INTO FINOPS.BUDGET_ACTION_LOG
  SELECT CURRENT_TIMESTAMP(), :BUDGET_NAME, 'THRESHOLD', :THRESHOLD_PCT, :BASIS, :DETAILS;

  -- Example actions (guardrails):
  -- ALTER WAREHOUSE <name> SET WAREHOUSE_SIZE = 'XSMALL';
  -- ALTER WAREHOUSE <name> SUSPEND;

  RETURN 'ok';
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Budget custom-action stored procedure contract (parameters, execution role, event payload) isn’t fully captured in release note text. | Automation may need different proc signature / permissions model. | Read budget docs: “Custom actions for budgets” + “Cycle-start actions for budgets”; test in a sandbox account. |
| ORG_USAGE premium views require org account + entitlement and may roll out gradually. | Feature may not be available in all customer environments. | Confirm view availability in org account; document prerequisites in app. |
| Native App config + inter-app communication are Preview features. | Behavior/limits may change. | Track release notes for changes; gate features behind capability checks. |

## Links & Citations

1. Feb 24, 2026 — User-defined actions for budgets: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
2. Feb 1, 2026 — New ORGANIZATION_USAGE premium views: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views
3. Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
4. Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
5. Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
6. Snowflake release notes index (for ongoing tracking): https://docs.snowflake.com/en/release-notes/new-features

## Next Steps / Follow-ups

- Pull the budget custom action docs and capture the exact stored procedure interface + security model; then build a ready-to-deploy “budget automations” schema.
- Prototype org-wide cost attribution queries against `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` (if available) and compare to ACCOUNT_USAGE Query History + metering rollups.
- For Native Apps: evaluate how “sensitive” config values behave in query history and logs; decide if we can safely collect required credentials via config rather than manual secret setup.
