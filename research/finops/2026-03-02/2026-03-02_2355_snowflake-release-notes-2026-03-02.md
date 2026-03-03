# Snowflake updates watch — 2026-03-02

**When:** 2026-03-02 23:55 UTC  
**Topic:** FinOps (primary) w/ Native Apps note  

## Executive summary
Release notes updates relevant to FinOps + platform automation:
- **Hybrid tables pricing simplified (effective Mar 1, 2026):** hybrid table *request* charges (serverless credits for row-store reads/writes) are removed as a separate billing category.
- **Budgets can trigger stored procedures (Feb 24, 2026):** lets teams auto-enforce governance/cost controls (suspend warehouses, alerting, logging) based on *projected or actual* spend thresholds; also supports cycle-start actions.
- **Native Apps configuration (Preview; Feb 20, 2026):** apps can request typed configuration values from consumers, including **sensitive** values masked from query history/command output.
- **Backups: unlimited backup sets per object (Mar 2, 2026):** ops change; potentially impacts storage/retention posture and cost tracking.

## What changed (facts)
### 1) Simplified pricing for hybrid tables (Mar 02, 2026)
- **Before:** hybrid tables billed via (1) hybrid table storage, (2) warehouse compute, (3) hybrid table requests (serverless credits for row storage ops).
- **Now (as of Mar 1, 2026):** no separate “hybrid table requests” billing category.
- **Remaining:**
  - Hybrid table storage: flat monthly $/GB
  - Warehouse compute: standard warehouse consumption for queries

**Source:** https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-hybrid-tables-pricing

### 2) User-defined actions for budgets (Feb 24, 2026)
- Budgets can now **call stored procedures**:
  - **Threshold actions:** trigger when projected or actual credits hit X%.
  - Up to **10** custom actions per budget.
  - **Cycle-start actions:** trigger when monthly cycle restarts (useful to undo prior enforcement actions).

**Source:** https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions

### 3) Native Apps: Application configurations (Preview; Feb 20, 2026)
- Native Apps can request **configuration values** from consumers.
- Keys can be marked **sensitive** so values are protected from exposure in query history / command output.

**Source:** https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration

### 4) Unlimited backup sets per object (Mar 02, 2026)
- Previously: max 2 backup sets per database/schema/table.
- Now: **unlimited** backup sets for a given object.

**Source:** https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-backups-no-limit-backup-sets

## Implications for a FinOps / Admin Native App
### Hybrid tables pricing change
- FinOps cost models and dashboards should **stop expecting a separate request-based credit line item** for hybrid tables.
- Opportunity: add an “effective-date-aware” cost explainer for hybrid tables that highlights the *old vs new* model.

### Budget stored-proc hooks
- Enables a **closed-loop** FinOps system:
  - When spend crosses thresholds, trigger stored procedures to (examples) suspend warehouses, set resource monitors, record an incident row, notify via external integration, etc.
- App could become an **opinionated generator** of:
  - Stored procedure templates + deployment
  - Budget definitions with staged thresholds

### Native Apps configuration (Preview)
- Removes a bunch of awkward “tell the consumer to run SQL with secrets” flows.
- Enables clean setup UX: app declares required config keys; consumer supplies values; app reads them securely.

### Unlimited backup sets
- More flexible DR/immutability workflows, but also more ways to accidentally accumulate cost.
- A FinOps app can add “backup set sprawl” checks if Snowflake exposes inventory/usage metrics for backup sets (not confirmed here).

## Snowflake objects & data sources (to verify)
*(Release notes did not specify specific views for these features; items below are follow-ups.)*
- Budgets:
  - Need to confirm which views/tables expose **budget definitions**, action history, and trigger events (ACCOUNT_USAGE? ORG_USAGE? INFORMATION_SCHEMA?).
- Hybrid tables:
  - Validate where hybrid table storage and compute show up in cost attribution (likely standard metering + storage). Confirm if any new billing dimensions were removed/renamed.
- Backups:
  - Verify what metadata exists for backup sets (SHOW commands? account usage views?) and whether costs can be attributed.

## MVP features unlocked (PR-sized)
1) **Budget Action Pack**: shipped stored procedures + docs that implement:
   - threshold: suspend list of warehouses
   - threshold: tag/record “spend incident” into a table
   - cycle-start: re-enable warehouses + notify
2) **Hybrid Table Cost Explainer**: UI card + documentation note: “request credits removed as of 2026-03-01” + how to forecast.
3) **Native App Config UX spike** (Preview): design config schema for:
   - external webhook endpoint
   - “server app” name for inter-app comm
   - API key storage (sensitive)

## Risks / assumptions
- Assumption: Hybrid table billing line items will disappear/merge cleanly across all billing exports; need to validate in a real account.
- Budgets stored-proc execution context/permissions may be non-trivial (role/ownership, execution rights). Need to confirm.
- Native Apps configuration is **Preview**; APIs/behavior might change.
- Backup sets: unlimited count could materially affect storage costs; unclear how observable the inventory is.

## Links
- Hybrid tables pricing: https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-hybrid-tables-pricing
- Budgets custom actions: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
- Native Apps configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
- Backup sets unlimited: https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-backups-no-limit-backup-sets
