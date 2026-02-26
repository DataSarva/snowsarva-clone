# Research: Native Apps - 2026-02-26

**Time:** 1717 UTC  
**Topic:** Snowflake Native Apps (+ FinOps-adjacent billing/budget updates)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Native Apps “Application configuration” is now available in Preview**: apps can define configuration keys and request values from consumers; keys can be marked **sensitive** to reduce exposure (e.g., in query history / command output). 
2. **Native Apps “Inter-App Communication” is now available in Preview**: apps in the same consumer account can communicate securely, enabling data sharing/merging across multiple Native Apps.
3. **Native Apps “Shareback” is now GA**: apps can request permission from consumers to share data back to the provider (or designated third parties) via a governed channel.
4. **Budgets can now trigger stored procedures** (custom threshold actions + cycle-start actions): enables automation like suspending warehouses, sending alerts, or logging spend events.
5. **Snowsight can now view/download invoices for On Demand accounts**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (TBD) Budget objects / metadata | (TBD) | Docs (user-guide budgets) | Need follow-up: what objects/views exist for budgets + actions (and which schemas). |
| Stored procedures invoked by budgets | Procedure | Customer account | New integration point: budget events → SP execution (FinOps automation hooks). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App install/config “wizard” pattern (Preview-ready):**
   - Define app configuration keys for required consumer inputs (e.g., *external URL*, *account identifier*, *server app name for IAC*).
   - Mark secrets as **sensitive**.
   - UI: validate presence + format of required keys before enabling core workflows.

2. **Composable “Mission Control” app ecosystem (Preview exploration):**
   - Use Inter-App Communication to integrate a FinOps app with a governance/observability companion app inside the same account.
   - Example: governance app provides classifications/tags; FinOps app consumes them to attribute cost.

3. **Shareback-based telemetry loop (GA):**
   - Use Shareback for opt-in export of anonymized usage telemetry / savings events / diagnostics to provider.
   - Can support “fleet learning” features (e.g., recommended budget thresholds, warehouse policies) without requiring external egress.

4. **Budget-action automations (FinOps):**
   - Ship sample stored procedures + setup guide that users can attach to budgets:
     - threshold reached → suspend specific warehouses / alert Slack/email via notification integration
     - cycle start → re-enable warehouses + reset “budget event” tables

## Concrete Artifacts

### Pseudocode: configuration keys + sensitive values

```text
APP defines configuration keys:
  - FINOPS_EXTERNAL_DASHBOARD_URL (string)
  - IAC_SERVER_APP_NAME (string)
  - PROVIDER_TELEMETRY_TOKEN (sensitive string)

Consumer provides values at install/setup.
App reads values at runtime; sensitive values should avoid appearing in query history/command output.
```

### Sketch: budget action stored procedure behavior

```sql
-- Example SP idea (names illustrative):
-- When budget reaches 90% projected usage, suspend a set of warehouses and log the action.
CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_ACTIONS.ON_THRESHOLD_REACHED()
RETURNS STRING
LANGUAGE SQL
AS
$$
  -- 1) insert audit row (timestamp, budget name, threshold, action)
  -- 2) ALTER WAREHOUSE ... SUSPEND for selected warehouses
  -- 3) optionally send notification (if configured)
  SELECT 'ok';
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Application configuration + Inter-App Communication are **Preview** (behavior/DDL/privileges may change). | Could require refactors in app packaging & docs. | Track the Native Apps dev guide pages + preview limitations. |
| “Sensitive” configuration values reduce exposure, but exact guarantees/edge cases are unclear from release note alone. | Security posture could be overstated. | Read the full app configuration doc + test: query history/command output leakage scenarios. |
| Budget SP triggers: unclear event payload/context passed to SP (budget name? threshold? projected vs actual?) from release note alone. | Automation may need additional metadata plumbing. | Read budgets “custom actions” + “cycle-start actions” docs; prototype in a test account. |

## Links & Citations

1. Snowflake release notes index (Feb 2026 items listed): https://docs.snowflake.com/en/release-notes/new-features  
2. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration  
3. Native Apps: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac  
4. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback  
5. User-defined actions for budgets (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions  
6. View invoices in Snowsight (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices

## Next Steps / Follow-ups

- Read + extract key details from:
  - Application configuration doc (keys, DDL, privilege model, how to read values at runtime)
  - Inter-App Communication doc (how apps discover each other, permissions, data sharing mechanics)
  - Budgets custom actions / cycle-start actions docs (what context is available inside SP)
- Decide whether Mission Control should:
  - adopt app configuration for install-time inputs
  - design IAC integration points now (behind a feature flag)
  - add a “budget automations” sample pack (procedures + templates)
