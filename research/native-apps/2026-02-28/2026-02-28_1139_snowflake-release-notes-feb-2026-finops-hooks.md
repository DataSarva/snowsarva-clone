# Research: Native Apps - 2026-02-28

**Time:** 1139 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps: “Shareback” is GA (Feb 10, 2026).** Native Apps can request permission from consumers to share data back with the provider or designated third parties via a governed channel. This is positioned for use cases like compliance reporting and telemetry/analytics sharing.  
2. **Native Apps: “Inter-App Communication” is Preview (Feb 13, 2026).** Native Apps can securely communicate with other apps in the same account, enabling sharing/merging of data across multiple apps inside a consumer account.  
3. **Native Apps: “Application configuration” is Preview (Feb 20, 2026).** Apps can define configuration keys to request values from consumers (e.g., server app name for inter-app comms, external URL, account identifier). Config keys can be marked **sensitive** to reduce exposure in query history / command output (e.g., tokens).  
4. **FinOps hook (Budgets): user-defined actions + cycle-start actions (Feb 24, 2026).** Budgets can call stored procedures when thresholds are reached (projected or actual) and at cycle start; up to 10 custom actions per budget.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| Budgets (feature) | N/A | Release note | Stored procedure callbacks are a new automation surface for FinOps responses. Exact DDL/API details are in linked user guide pages (not extracted in this pass). |
| Native App “application configuration” | N/A | Release note | Includes notion of sensitive configuration values to prevent leakage in query history / output. |
| Native App inter-app communication | N/A | Release note | Preview; likely implies new privileges/objects; needs doc deep-dive. |
| Native App shareback | N/A | Release note | GA; implies app-spec / listing flow for requesting permissions for shareback. |

## MVP Features Unlocked

1. **“Provider telemetry shareback” baseline:** add an optional module to the FinOps Native App that (when enabled by consumer) sharebacks aggregated cost/usage metrics to provider for fleet benchmarking and proactive optimization recommendations.
2. **Consumer-supplied config for integration targets (Preview):** add “configuration keys” for (a) webhook endpoint, (b) Slack/Teams integration token, (c) target database/schema, marked sensitive where applicable.
3. **Budget-driven automation pack:** ship a set of stored procedures + reference snippets that customers can attach to Snowflake Budgets to: suspend warehouses, apply resource monitors, emit alerts, and log events into an APP-owned table.

## Concrete Artifacts

### Stored procedure callbacks for budget actions (skeleton)

```sql
-- PSEUDOCODE / SKELETON (exact signature/inputs TBD from Snowflake docs)
-- Goal: idempotent response when a budget threshold triggers.

CREATE OR REPLACE PROCEDURE FINOPS.BUDGET_THRESHOLD_ACTION(/* inputs TBD */)
RETURNS STRING
LANGUAGE SQL
AS
$$
  -- 1) Write an event record (budget, threshold, actual vs projected, ts)
  -- 2) Decide action (e.g., suspend specific warehouses or notify)
  -- 3) Enforce idempotency (don’t spam actions per cycle)
  RETURN 'ok';
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Preview features (inter-app comms, app configuration) may change semantics/APIs before GA. | Integration work could churn. | Track release notes; deep-read linked dev guide pages. |
| “Sensitive configuration” claim is based on release note wording; implementation details may differ. | Could still leak in some contexts. | Validate with docs + practical tests (query history, SHOW output). |
| Budget stored procedure call interface (inputs, execution context, privileges) not captured here. | Hard to ship production-safe automation without details. | Pull + annotate `Custom actions for budgets` and `Cycle-start actions` docs. |

## Links & Citations

1. Release notes index (shows feature updates list, incl. Native Apps + budgets): https://docs.snowflake.com/en/release-notes/new-features
2. Native Apps: Configuration (Preview) (Feb 20, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-20-nativeapps-configuration
3. Native Apps: Inter-App Communication (Preview) (Feb 13, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
4. Native Apps: Shareback (GA) (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
5. Budgets: User-defined actions + cycle-start actions (Feb 24, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-budget-user-defined-actions

## Next Steps / Follow-ups

- Deep-read + extract details from the linked dev guide pages:
  - Application configuration
  - Inter-app communication
  - Requesting app specs / permissions flow for shareback
- Deep-read + extract details from budgets docs:
  - Stored procedure signature + execution role/context
  - Guardrails / quotas / retry semantics
- Decide whether to prototype:
  - (A) budget-action SP starter kit (fast FinOps win)
  - (B) app configuration keys usage in our Native App UX
