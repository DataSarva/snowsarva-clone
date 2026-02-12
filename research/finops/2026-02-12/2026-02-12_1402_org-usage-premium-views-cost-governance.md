# Research: FinOps - 2026-02-12

**Time:** 14:02 UTC
**Topic:** Snowflake ORG_USAGE Premium Views for Cost Governance
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake released three new **premium ORGANIZATION_USAGE views** on Feb 01, 2026: METERING_HISTORY (hourly credit usage per account), NETWORK_POLICIES, and QUERY_ATTRIBUTION_HISTORY (compute cost per query org-wide).

2. **QUERY_ATTRIBUTION_HISTORY** enables query-level cost attribution across an entire organization — critical for cross-account chargeback models. Latency is up to 24 hours. CREDITS_ATTRIBUTED_COMPUTE excludes warehouse idle time.

3. **APPLICATION_DAILY_USAGE_HISTORY** (ACCOUNT_USAGE) provides Native App-specific consumption tracking, breaking down credits by service type (SNOWPARK_CONTAINER_SERVICES, SERVERLESS_TASK, AUTO_CLUSTERING, etc.) and storage by type (DATABASE, FAILSAFE, HYBRID_TABLE).

4. Snowflake officially joined the **FinOps Foundation** as a Premier Enterprise Member, signaling increased investment in cost governance capabilities and FOCUS specification alignment.

5. Infrastructure costs for Native Apps with SPCS are fully consumer-owned; providers can monetize via Marketplace pricing models, but compute pools, storage, and data transfer are consumer responsibilities.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| METERING_HISTORY | Premium View | `SNOWFLAKE.ORGANIZATION_USAGE` | Hourly credit usage; Feb 2026 release; premium account required |
| QUERY_ATTRIBUTION_HISTORY | Premium View | `SNOWFLAKE.ORGANIZATION_USAGE` | Query-level credit attribution; 24h latency |
| NETWORK_POLICIES | Premium View | `SNOWFLAKE.ORGANIZATION_USAGE` | Cross-account network policy visibility |
| APPLICATION_DAILY_USAGE_HISTORY | Standard View | `SNOWFLAKE.ACCOUNT_USAGE` | Native App daily credit/storage breakdown; 1 day latency |
| WAREHOUSE_METERING_HISTORY | Standard View | `SNOWFLAKE.ACCOUNT_USAGE` | Hourly credit usage per warehouse |
| TABLE_STORAGE_METRICS | Standard View | `SNOWFLAKE.ACCOUNT_USAGE` | Storage metrics for cost attribution |
| TAG_REFERENCES | Standard View | `SNOWFLAKE.ACCOUNT_USAGE` | Object tagging for granular cost allocation |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata (24h latency typically)
- `ORGANIZATION_USAGE` = Organization-level visibility (premium views may require specific edition)
- `INFO_SCHEMA` = Database-level metadata

---

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Query-Level Chargeback Report**: Build a Native App view that joins `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` with user/session context to generate per-team/per-user chargeback statements. MVP: CSV export of top 100 cost drivers by user/warehouse/week.

2. **Native App Cost Explorer Widget**: Surface `APPLICATION_DAILY_USAGE_HISTORY` data in the FinOps Native App with drill-down by service type (SPCS, serverless tasks) and storage type. Useful for consumers running provider apps.

3. **Org-Wide Budget Alerting**: Use `METERING_HISTORY` to build proactive hourly alerts when credit consumption exceeds configurable thresholds by account or service type. Can be implemented via scheduled tasks + notification integration.

---

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Query Attribution Chargeback Query

```sql
-- Attribution of compute costs by user and warehouse
SELECT 
    ACCOUNT_NAME,
    USER_NAME,
    WAREHOUSE_NAME,
    DATE(START_TIME) AS query_date,
    SUM(CREDITS_ATTRIBUTED_COMPUTE) AS total_compute_credits,
    SUM(CREDITS_USED_QUERY_ACCELERATION) AS qas_credits,
    COUNT(*) AS query_count
FROM SNOWFLAKE.ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4
ORDER BY total_compute_credits DESC;
```

### Native App Daily Usage Monitoring

```sql
-- Track SPCS and other service costs for installed Native Apps
SELECT 
    APPLICATION_NAME,
    LISTING_GLOBAL_NAME,
    USAGE_DATE,
    CREDITS_USED,
    VALUE:"credits"::NUMBER AS service_credits,
    VALUE:"serviceType"::STRING AS service_type
FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY,
LATERAL FLATTEN(INPUT => CREDITS_USED_BREAKDOWN)
WHERE USAGE_DATE >= DATEADD(DAY, -30, CURRENT_DATE())
  AND VALUE:"serviceType"::STRING = 'SNOWPARK_CONTAINER_SERVICES'
ORDER BY USAGE_DATE DESC, service_credits DESC;
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Premium views require Enterprise edition or higher | BLOCKING for teams on standard edition | Confirm account edition before shipping features |
| QUERY_ATTRIBUTION_HISTORY latency up to 24h | Delayed alerts; not suitable for real-time enforcement | Document in product limitations; use for trend analysis |
| APPLICATION_DAILY_USAGE_HISTORY timezone handling discrepancies with Snowsight | Confusion in cost reporting | Always set TIMEZONE to UTC for consistent results |
| Org-wide views require ORGANIZATION_USAGE_VIEWER role | Feature unavailable to non-admin users | Add role check and graceful fallback |

---

## Links & Citations

1. https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views — Feb 01, 2026 release notes for ORGANIZATION_USAGE premium views
2. https://docs.snowflake.com/en/sql-reference/organization-usage/query_attribution_history — QUERY_ATTRIBUTION_HISTORY view documentation
3. https://docs.snowflake.com/en/sql-reference/organization-usage/metering_history — METERING_HISTORY view documentation
4. https://docs.snowflake.com/en/sql-reference/account-usage/application_daily_usage_history — Native App daily usage tracking
5. https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance — SPCS Native App cost governance
6. https://www.snowflake.com/en/pricing-options/cost-and-performance-optimization/ — Snowflake FinOps Foundation membership announcement

---

## Next Steps / Follow-ups

- [ ] Verify ORGANIZATION_USAGE premium views availability in target test account
- [ ] Prototype QUERY_ATTRIBUTION_HISTORY join with user/session mapping table
- [ ] Document FOCUS specification alignment for query export format
- [ ] Review cost allocation strategy with tags vs. query attribution approach
