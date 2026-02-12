# Research: Native Apps - 2026-02-12

**Time:** 09:07 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps now support **“Shareback”**: an app can request permission from a consumer to **share data back** to the provider (or a designated third party) via a governed channel. This capability is **GA** as of 2026-02-10. 
2. The Shareback capability is explicitly positioned for **compliance reporting**, **telemetry/analytics sharing**, and **data preprocessing**, i.e., provider-side processing based on consumer-authorized data sent back.
3. Snowflake announced upcoming server-release work that includes **permission model updates** for *owner’s-rights contexts* (including Native Apps) to support a wider set of introspection commands (listed under 10.3–10.6 release overview).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| (Native App) app specification / permission request flow | App framework | Docs | Shareback is enabled via a permission request + consumer approval workflow (“Request data sharing with app specifications”). Exact object names/DDL not captured in this pass. |
| ACCOUNT_USAGE / ORGANIZATION_USAGE telemetry tables (provider-side) | Views | Docs (implied) | Shareback is a mechanism to *receive* consumer-authorized data back. Exact landing objects depend on the Shareback spec configuration (needs follow-up). |

## MVP Features Unlocked

1. **Opt-in “Provider Telemetry” channel for the FinOps Native App**: request Shareback permission so consumers can send back (a) app usage events, (b) aggregated cost KPIs, or (c) redacted diagnostic bundles for support.
2. **Compliance export / audit pack**: use Shareback to allow a consumer to transmit required evidence artifacts (e.g., configs, policies, attestations) back to provider for validation workflows.
3. **Cross-account benchmarking (privacy-preserving)**: collect opt-in, aggregated metrics across consumers to build baselines (warehouse efficiency bands, anomaly rates) and feed “what good looks like” recommendations.

## Concrete Artifacts

### Draft: data contract for Shareback telemetry (concept)

```yaml
# Pseudo-spec (illustrative)
telemetry:
  version: 1
  events:
    - name: "finops.app_open"
      fields: [timestamp, account_locator_hash, app_version]
    - name: "finops.anomaly_reviewed"
      fields: [timestamp, anomaly_type, resolution]
  kpis:
    - name: "warehouse_utilization_p50"
      granularity: "daily"
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Shareback implementation details (DDL, where data lands, quotas/limits, governance controls) aren’t captured in this quick scan. | Could mis-design the telemetry pipeline or permission request. | Read the “Request data sharing with app specifications” doc end-to-end and prototype in a dev Native App package. |
| Consumers may be sensitive to sending any telemetry back (even aggregated). | Lower adoption if the value isn’t clear and controls aren’t strong. | Provide explicit opt-in scopes + clear data minimization; offer “support-only” mode. |
| Permission-model updates for owner’s-rights introspection might change behavior for app diagnostics. | App could break if relying on current limitations/workarounds. | Track 10.3 release notes + test on accounts as releases roll out. |

## Links & Citations

1. Snowflake Release Note: **Feb 10, 2026 – Snowflake Native Apps: Shareback (GA)**
   https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. “Release notes overview: 10.3–10.6” (mentions Native Apps/Streamlit permission model updates)
   https://docs.snowflake.com/en/release-notes/2026/10_3-10_6

## Next Steps / Follow-ups

- Read and summarize: “Request data sharing with app specifications” (identify exact objects/roles/flows + consumer UX in Snowsight).
- Decide on a minimal telemetry schema for Mission Control (FinOps app) and how to store/process it provider-side.
- Evaluate whether Shareback can carry: raw events vs. aggregates vs. files (e.g., zipped diagnostics) and how that maps to app permissions.
