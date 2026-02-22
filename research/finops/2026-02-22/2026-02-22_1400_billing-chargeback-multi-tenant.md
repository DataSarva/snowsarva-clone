# Research: FinOps - 2026-02-22

**Time:** 1400 UTC
**Topic:** Snowflake Native App Billing, Chargeback & Multi-Tenant Cost Allocation
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **Multi-tenant cost estimation requires systematic modeling.** Snowflake costs vary significantly tenant-by-tenant in multi-tenant architectures. A practical framework must separate fixed infrastructure costs from variable consumption costs per tenant. (Source: Medium/Sajal Agarwal)

2. **Four primary data monetization strategies exist:** (a) Selling raw or aggregated data via marketplace, (b) Data-as-a-Service (DaaS) via APIs, (c) Analytics/insights-as-a-product, (d) Data-enhanced products/services. Native Apps fit strategies b, c, and d. (Source: Snowflake docs)

3. **Snowflake Well-Architected Framework recommends chargeback models for FinOps maturity.** Chargeback directly bills departments for usage, creating financial incentive for optimization. This requires robust tagging and attribution foundations. (Source: Snowflake Well-Architected)

4. **Tagging strategies enable granular cost allocation.** Object Tags (databases, warehouses, tables) + Query Tags (session-level) combine to attribute costs to teams/projects even with shared resources. TAG_REFERENCES view joins with WAREHOUSE_METERING_HISTORY and QUERY_HISTORY. (Source: Snowflake docs)

5. **Native Snowflake tools (Resource Monitors, Budgets) are safety nets, not optimization engines.** They show spending limits hit but don't explain why costs climbed or which queries/teams drove spikes. Third-party tools or custom Native Apps needed for deep attribution. (Source: Ternary blog)

6. **Cost allocation models: Shared vs Dedicated warehouses.** Shared resources = harder attribution (requires query tags); Dedicated resources = clear attribution (per-tenant warehouses) but higher overhead. Common pattern: start shared, graduate to dedicated as workload grows. (Source: Snowflake Well-Architected)

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Credit consumption by warehouse |
| QUERY_HISTORY | View | ACCOUNT_USAGE | Query-level details including QUERY_TAG |
| TAG_REFERENCES | View | ACCOUNT_USAGE | Links tags to objects for allocation |
| TABLE_STORAGE_METRICS | View | ACCOUNT_USAGE | Storage costs by table/object |
| DATABASES | View | ACCOUNT_USAGE | Database-level metadata |
| WAREHOUSES | View | ACCOUNT_USAGE | Warehouse configuration and state |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level (ORGANIZATION_USAGE schema)
- `INFO_SCHEMA` = Database-level (per-database)

---

## MVP Features Unlocked
*PR-sized ideas that can be shipped based on these findings.*

1. **Tenant Cost Attribution Dashboard (Native App)**
   - Aggregate costs by tenant using query tagging strategy
   - Show compute vs storage breakdown per tenant
   - Link to Snowsight pre-built cost views

2. **Chargeback Report Generator (SQL + Streamlit)**
   - Monthly invoicing-style reports per department/tenant
   - Blended rate calculations (include markup/down margins)
   - Export to CSV/Excel for finance teams

3. **Query Tag Enforcement Checker**
   - Identify untagged queries in shared warehouses
   - Automatic alerts when attribution coverage drops
   - Recommendations for tag-based cost allocation

---

## Concrete Artifacts

### SQL Draft: Tenant Cost Attribution with Query Tags

```sql
-- Attribution model for multi-tenant Native App using QUERY_TAG
-- Assumes QUERY_TAG is set to 'tenant_id:<tenant_id>' by app

WITH tenant_compute AS (
  SELECT
    PARSE_JSON(QUERY_TAG):tenant_id::STRING as tenant_id,
    WAREHOUSE_NAME,
    SUM(EXECUTION_TIME) / 1000 / 60 / 60 as hours,
    SUM(TOTAL_ELAPSED_TIME) / 1000 / 60 / 60 * 
      (SELECT CURRENT_ACCOUNT()) as credits_consumed,
    COUNT(*) as query_count
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE())
    AND QUERY_TAG IS NOT NULL
    AND QUERY_TAG LIKE '%tenant_id%'
  GROUP BY 1, 2
),
tenant_storage AS (
  SELECT
    TABLE_SCHEMA as tenant_id,  -- Assuming schema-per-tenant model
    SUM(BYTES) / POWER(1024, 3) as storage_gb,
    SUM(TABLES) as table_count
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
  WHERE DELETED = FALSE
  GROUP BY 1
),
cost_rates AS (
  -- Standard Snowflake rates (varies by region/edition)
  SELECT 
    2.00 as compute_credit_price,  -- $/credit (Enterprise example)
    0.027 as storage_tb_price      -- $/TB/day
)

SELECT
  COALESCE(tc.tenant_id, ts.tenant_id) as tenant_id,
  COALESCE(tc.credits_consumed, 0) * cr.compute_credit_price as compute_cost,
  COALESCE(ts.storage_gb, 0) / 1024 * cr.storage_tb_price * 30 as storage_cost_monthly,
  COALESCE(tc.query_count, 0) as query_count
FROM tenant_compute tc
FULL OUTER JOIN tenant_storage ts ON tc.tenant_id = ts.tenant_id
CROSS JOIN cost_rates cr
ORDER BY compute_cost DESC;
```

### ADR: Chargeback Model Selection

**Context:** Need to bill internal teams/tenants for Snowflake usage

**Decision:** Implement hybrid model
- **Phase 1:** Showback (visibility only) - learn patterns
- **Phase 2:** Chargeback with 10% markup for platform costs
- **Phase 3:** Showback with dedicated warehouses for large tenants

**Consequences:**
- (+) Incentivizes tenant optimization
- (+) Recovers platform overhead costs
- (-) Requires accurate attribution (risk: disputes)
- (-) Finance overhead for invoicing

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Query tags are consistently set by application | High | Audit QUERY_HISTORY coverage weekly |
| Tenants accept chargeback methodology | Medium | Pilot with 1-2 friendly teams first |
| Credit rates are stable for budgeting | Medium | Lock rates in contract or use averages |
| Storage attribution by schema maps to tenant | Medium | Verify schema-per-tenant pattern |
| ORG_USAGE views available for cross-account | High | Check edition/entitlement |
| Blended rates cover actual costs | Medium | Reconcile monthly with actual bill |

---

## Links & Citations

1. [Snowflake Data Monetization Strategies](https://www.snowflake.com/en/fundamentals/data-monitization/) - 4 major data monetization strategies and challenges

2. [Snowflake Cost Estimation for Multi-Tenant Architectures (Medium)](https://medium.com/@sajal.agarwalcse/the-ultimate-guide-to-snowflake-cost-estimation-for-multi-tenant-architectures-d13ae66dea18) - Practical framework for modeling costs in multi-tenant systems

3. [Snowflake Well-Architected: Cost Optimization & FinOps](https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/) - Tagging strategies, attribution models, chargeback recommendations

4. [Snowflake Cost Management Tools Comparison (Ternary)](https://ternary.app/blog/top-snowflake-cost-management-tools/) - Why native tools are insufficient; platform requirements

5. [Snowflake Native Apps: Build & Monetize (Flexera)](https://www.flexera.com/blog/finops/snowflake-native-apps/) - Native App monetization patterns

---

## Next Steps / Follow-ups

- [ ] Deep-dive: ORGANIZATION_USAGE schema for cross-account aggregation
- [ ] Research: Snowflake Marketplace metering/billing APIs for Native Apps
- [ ] Prototype: Query Tag injection in Streamlit/Native App connector
- [ ] Validate: Actual credit pricing for Akhil's account/region
- [ ] Compare: Ternary vs Select.dev vs custom Native App cost visibility

---

*Generated: 2026-02-22 14:00 UTC | Next research cycle: 2026-02-22 16:00 UTC*
