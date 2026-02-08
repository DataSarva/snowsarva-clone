# Snowflake FinOps + Native Apps Research Digest
**Date:** 2026-02-08  
**Topic:** FinOps, Native Apps, Snowpark Container Services  
**Sources:** Snowflake Release Notes (Feb 6, 2026), Snowflake Documentation

---

## Accurate Takeaways

### Trust Center Overview Tab (Preview) - Feb 06, 2026
- Snowflake released a new **Trust Center Overview tab** in Preview on Feb 6, 2026
- This provides centralized visibility into security and compliance posture
- Critical for FinOps apps dealing with governance and cost-sensitive data

### Listing & Share Observability (GA) - Feb 02, 2026
- **New ACCOUNT_USAGE views** for provider-side observability:
  - `ACCOUNT_USAGE.LISTINGS` - metadata on marketplace listings
  - `ACCOUNT_USAGE.SHARES` - provider share configurations
  - `ACCOUNT_USAGE.GRANTS_TO_SHARES` - granular grant visibility
- **INFORMATION_SCHEMA additions**:
  - `INFORMATION_SCHEMA.LISTINGS` - consumer-facing listing discovery
  - `INFORMATION_SCHEMA.SHARES` - share metadata for both providers/consumers
  - `INFORMATION_SCHEMA.AVAILABLE_LISTINGS` table function
- **Updated ACCESS_HISTORY** includes grants to shares
- **Latency:** 45min-3hours for ACCOUNT_USAGE, real-time for INFORMATION_SCHEMA

### New ORGANIZATION_USAGE Premium Views - Feb 01, 2026
- Additional premium views available at organization level for multi-account cost visibility
- Critical for enterprise FinOps scenarios with multiple Snowflake accounts

---

## Snowflake Objects & Data Sources (for Native App FinOps)

| Data Source | Schema | Type | Latency | Key Metrics |
|-------------|--------|------|---------|-------------|
| `QUERY_HISTORY` | ACCOUNT_USAGE | Historical | 45min | Cost, duration, warehouse |
| `WAREHOUSE_METERING_HISTORY` | ACCOUNT_USAGE | Historical | 3hr | Credits consumed |
| `WAREHOUSE_EVENTS_HISTORY` | ACCOUNT_USAGE | Historical | 3hr | Auto-suspend events |
| `AUTOMATIC_CLUSTERING_HISTORY` | ACCOUNT_USAGE | Historical | 3hr | Clustering costs |
| `STAGE_STORAGE_USAGE_HISTORY` | ACCOUNT_USAGE | Historical | 3hr | Storage costs |
| `LOGINS` | ACCOUNT_USAGE | Historical | 2hr | Session/concurrency |
| `CORTEX_FUNCTIONS_USAGE_HISTORY` | ACCOUNT_USAGE | Historical | 1hr | AI feature costs |
| `CORTEX_AISQL_USAGE_HISTORY` | ACCOUNT_USAGE | Historical | varies | AI SQL costs |
| `COMPUTE_POOLS` | ACCOUNT_USAGE | Historical | 3hr | SPCS compute costs |
| `APPLICATIONS` | INFORMATION_SCHEMA | Object | Real-time | Installed apps |
| `LISTINGS` | INFORMATION_SCHEMA | Object | Real-time | Marketplace listings |

---

## MVP Features Unlocked (PR-sized)

### PR 1: Trust Center Integration Widget
**Scope:** Add a Trust Center compliance widget to the FinOps Native App dashboard  
**Data Source:** Leverage new trust center APIs when GA becomes available  
**Size:** 2-3 days, single Streamlit component  
**Value:** Shows governance posture alongside cost metrics

### PR 2: Share Cost Attribution
**Scope:** Build cost attribution for data sharing using new `GRANTS_TO_SHARES` + `ACCESS_HISTORY`  
**Data Source:** `ACCOUNT_USAGE.GRANTS_TO_SHARES` joined with `QUERY_HISTORY`  
**Size:** 3-4 days, new view + UI updates  
**Value:** Native Apps can attribute costs to specific data consumers

---

## Risks / Assumptions

1. **Trust Center API availability** - Currently Preview/Public Preview, API surface may change
2. **ORGANIZATION_USAGE requires Enterprise+** - Multi-account features gated by edition
3. **Data latency** - ACCOUNT_USAGE has 45min-3hr lag; real-time alerting requires INFORMATION_SCHEMA
4. **SPCS cost visibility** - COMPUTE_POOLS tracks SPCS, but granular per-service cost tracking requires custom aggregation
5. **ACCESS_HISTORY** - While recently updated, large accounts may see query performance issues on joins

---

## Links & Citations

1. **Snowflake Release Notes (Feb 6, 2026):** https://docs.snowflake.com/en/release-notes/new-features/2026/other/2026-02-06-trust-center-overview-tab-preview

2. **Listing & Share Observability GA (Feb 2, 2026):** https://docs.snowflake.com/en/release-notes/new-features/2026/other/2026-02-02-listing-observability-ga

3. **Account Usage Views Reference:** https://docs.snowflake.com/en/sql-reference/account-usage

4. **Native Apps Framework Overview:** https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about

5. **Snowpark Container Services Overview:** https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview

---

## Feature Ideas for Akhil (Native App FinOps)

1. **Budget Anomaly Detection** - Use `ANOMALIES_DAILY` view + custom thresholds for proactive alerting

2. **Share ROI Calculator** - New `LISTINGS` + `SHARES` views enable calculating revenue/cost per share

3. **SPCS Cost Explorer** - Visualize `COMPUTE_POOLS` usage with breakdown by service/job type

4. **Cortex Cost Tracking** - Dedicated dashboard for AI feature costs via `CORTEX_*_USAGE_HISTORY` views

5. **Cross-Account Cost Consolidation** - Leverage `ORGANIZATION_USAGE` for enterprise-wide cost visibility

6. **Query Cost Attribution by Team** - Enhanced GROUP BY on `QUERY_HISTORY` with metadata tags

7. **Storage Lifecycle Optimizer** - Recommend cold storage/archival based on `STAGE_STORAGE_USAGE_HISTORY`

8. **Warehouse Right-Sizing** - Automated recommendations using `WAREHOUSE_METERING_HISTORY` + `WAREHOUSE_EVENTS_HISTORY`

9. **Trust Center Compliance Scorecard** - Integrate governance metrics when API stabilizes

10. **Native App Marketplace Analytics** - For providers: track app installs, usage, and revenue via `APPLICATION_DAILY_USAGE_HISTORY`

---

## PR Recommendation (This Week)

**Task:** Implement "Share Cost Attribution" feature  
**Why now:** New `GRANTS_TO_SHARES` + updated `ACCESS_HISTORY` just went GA - this is a greenfield feature with no competition yet  
**Scope:** 
- SQL view joining `ACCOUNT_USAGE.GRANTS_TO_SHARES` with `ACCOUNT_USAGE.QUERY_HISTORY`
- Streamlit widget showing cost per share/listing
- Exportable attribution report
**Estimated effort:** 3-4 days  
**Blocker risk:** Low - uses GA features

---

*Research compiled by Snow ❄️ | Sources accessed: 2026-02-08*
