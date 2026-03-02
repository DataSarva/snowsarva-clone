# Research: Native Apps - 2026-03-02

**Time:** 1151 UTC  
**Topic:** Snowflake Native App Framework (+ adjacent FinOps updates)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps: “Application configuration” is now available in Preview**, allowing an app to define configuration keys and request values from the consumer (e.g., external URL/account identifier, or a server app name for inter-app comms). Configurations can be marked **sensitive** to avoid exposure in query history/command output.  
   Source: Feb 20, 2026 release note “Snowflake Native Apps: Configuration (Preview)”.

2. **Native Apps: “Shareback” is now GA**, enabling providers to request consumer permission to share data back to the provider (or designated third parties) through a governed channel. Snowflake positions it for telemetry/analytics, compliance reporting, etc.  
   Source: Feb 10, 2026 release note “Snowflake Native Apps: Shareback (General Availability)”.

3. **Native Apps: “Inter-App Communication” is now available in Preview**, enabling secure communication between apps in the same account, with the intent of sharing/merging data across multiple apps in a consumer account.  
   Source: Feb 13, 2026 release note “Snowflake Native Apps: Inter-App Communication (Preview)”.

4. **Budgets can now run stored procedures automatically** (user-defined actions) when (a) spending thresholds are reached (projected or actual) and (b) at budget cycle start. Up to **10 custom actions per budget**.  
   Source: Feb 24, 2026 release note “User-defined actions for budgets”.

5. **Snowsight now supports viewing/downloading invoices** for On Demand accounts.  
   Source: Feb 24, 2026 release note “View invoices in Snowsight”.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| (TBD) Native app configuration objects/APIs | (TBD) | Native Apps “Application configuration” docs | Need to read the developer guide page to identify concrete SQL objects, if any, vs purely UI/DDL-driven config APIs. |
| Stored procedures used as budget actions | SQL object | Budgets “Custom actions” docs | Mechanism is “call stored procedure on threshold/cycle start”; determine execution context + privileges. |
| Billing invoices in Snowsight | UI / billing | Billing invoices docs | Likely no new SQL view implied; confirm whether invoices are exposed via ACCOUNT_USAGE/ORG_USAGE or only UI/download. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked

1. **Native App “setup wizard” via configuration keys**  
   Add a first-run setup experience that requests consumer-provided inputs (e.g., webhook URL, account identifier, external system tenant id). Mark secrets as sensitive so they don’t leak into query history.

2. **Provider-side telemetry pipeline via Shareback (GA)**  
   Implement an opt-in “Send anonymized usage & cost telemetry” toggle that uses Shareback for governed data exchange back to the provider. Enables:
   - benchmark insights across customers,
   - proactive alerting for runaway spend,
   - “compare to peers” dashboards (aggregated).

3. **Cross-app integration story with Inter-App Communication (Preview)**  
   If the product ends up split into multiple apps (e.g., “FinOps Core” + “Governance” + “Observability”), use IAC to share canonical usage/cost datasets and avoid duplicated ingestion.

4. **FinOps automation hooks using Budget stored-procedure actions**  
   Ship a reference stored procedure (and docs) that budgets can call to:
   - suspend/resize warehouses,
   - pause non-critical tasks,
   - write spend events to an audit table,
   - send alert via external notification integration.

---

## Concrete Artifacts

### Draft: “Budget action” stored procedure interface (proposed)

Assumption: Snowflake passes *some* context (budget name/id, threshold, actual/projected usage) to the procedure; if not, we’ll look it up based on known identifiers.

```sql
-- PSEUDOCODE / PROPOSED INTERFACE (needs validation against docs)
CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_ACTION_HANDLER(
  EVENT_TYPE STRING,   -- e.g. THRESHOLD_REACHED | CYCLE_START
  BUDGET_NAME STRING,
  THRESHOLD_PCT NUMBER,
  MODE STRING          -- ACTUAL | PROJECTED
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
  -- Example actions:
  -- 1) Log event
  INSERT INTO FINOPS.BUDGET_EVENTS(event_ts, event_type, budget_name, threshold_pct, mode)
  VALUES (CURRENT_TIMESTAMP(), :EVENT_TYPE, :BUDGET_NAME, :THRESHOLD_PCT, :MODE);

  -- 2) Optional enforcement
  -- ALTER WAREHOUSE <name> SUSPEND;

  RETURN OBJECT_CONSTRUCT('ok', TRUE);
$$;
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| “Application configuration” has concrete SQL APIs and clear secret-handling semantics beyond “not in query history/command output”. | Could mis-design secret storage/rotation. | Read developer guide page; test behavior with sensitive configs and query history. |
| Shareback GA specifics (who owns the shared objects, revocation, row-level controls, auditability) aren’t captured in release note. | Telemetry design might violate least privilege or be brittle. | Read the “Request data sharing with app specifications” docs + run a POC. |
| Budget action procedure execution context (role, warehouse, timeout, parameters) may have constraints. | Automation could fail or require elevated privileges. | Read budget custom actions docs; test in a sandbox account. |

---

## Links & Citations

1. Snowflake release notes index (recent feature updates): https://docs.snowflake.com/en/release-notes/new-features
2. Feb 20, 2026 — Native Apps: Configuration (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
3. Feb 10, 2026 — Native Apps: Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
4. Feb 13, 2026 — Native Apps: Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
5. Feb 24, 2026 — User-defined actions for budgets: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions
6. Feb 24, 2026 — View invoices in Snowsight: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-billing-invoices

---

## Next Steps / Follow-ups

- Read the linked developer guide pages for:
  - Application configuration
  - Inter-app communication
  - Requesting app specs / Shareback
- Decide if our FinOps Native App should:
  - use configs for “first-run setup”,
  - offer Shareback-based telemetry (opt-in),
  - publish a reference “budget automation” stored procedure pack.
