# Research: FinOps - 2026-02-23

**Time:** 0754 UTC
**Topic:** Snowflake FinOps Cost Optimization
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. **Snowflake credits are the universal currency for all compute resources**, but billing mechanics differ by resource type (virtual warehouses, serverless features, cloud services, Compute Pools for SPCS). Credits consumed by serverless features are calculated in compute-hours, rounded up to the nearest second, while warehouse credits use per-second billing with a 60-second minimum. [source](https://docs.snowflake.com/en/user-guide/cost-understanding-compute)

2. **APPLICATION_DAILY_USAGE_HISTORY (ORGANIZATION_USAGE schema)** provides daily credit usage for Native Apps within an account, covering warehouses, serverless, and cloud services. This is the primary view for building Native App cost attribution dashboards. [source](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)

3. **Snowpark Container Services (SPCS) uses Compute Pools**, which are collections of VM nodes. Cost scales with the number and type of nodes in the pool. GPU-enabled machine types consume credits at different rates than CPU-only pools. Unlike virtual warehouses, compute pools auto-scale within min/max node boundaries. [source](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)

4. **Cloud Services consumption is only billed if daily consumption exceeds 10% of daily warehouse usage**. The daily adjustment is calculated in UTC and shown in METERING_DAILY_HISTORY with a credit adjustment column. Serverless compute does NOT factor into this 10% adjustment. [source](https://docs.snowflake.com/en/user-guide/cost-understanding-compute)

5. **Tags enable cost attribution to logical units** (cost centers, environments, business lines). The Consumption dashboard supports filtering by tag/value pairs, enabling chargeback/showback models for Native Apps that serve multiple tenants or departments.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `ORGANIZATION_USAGE.APPLICATION_DAILY_USAGE_HISTORY` | ORG_USAGE | Native Apps cost | Daily credit breakdown by app within organization |
| `ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | ORG_USAGE | Compute + Cloud Services | Shows actual billed credits after 10% cloud services adjustment |
| `ORGANIZATION_USAGE.METERING_HISTORY` | ORG_USAGE | Hourly consumption | Credits consumed by warehouses, cloud services, serverless by hour |
| `ACCOUNT_USAGE.METERING_DAILY_HISTORY` | ACCOUNT_USAGE | Account-level compute | Same as ORG version but scoped to single account |
| `ACCOUNT_USAGE.METERING_HISTORY` | ACCOUNT_USAGE | Hourly account consumption | Hourly credit consumption per account |
| `ORGANIZATION_USAGE.COMPUTE_POOLS` | ORG_USAGE | SPCS infra | Compute pool node counts, statuses for SPCS cost tracking |
| `TAG` | INFO_SCHEMA | Resource attribution | Cost center/project tagging for chargeback |
| `APPLICATION DAILY USAGE` | ORG_USAGE | New (Preview) | Specifically tracks Native App daily credit consumption |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Native App Cost Dashboard v0.1**: Query `APPLICATION_DAILY_USAGE_HISTORY` to build a per-app cost breakdown showing credits by compute type (warehouses, serverless, cloud services). Target: single view with 7-day rolling cost and cost-per-user metric.

2. **SPCS Compute Pool Cost Monitor**: Build SQL view joining `COMPUTE_POOLS` with `ORGANIZATION_USAGE` tables to track active node usage, credit burn rate, and projected daily cost for SPCS-based services. Alert when pool approaches max nodes.

3. **Cloud Services Billed vs Consumed Reconciler**: Create reconciliation report using `METERING_DAILY_HISTORY.CLOUD_SERVICES_ADJUSTMENT` column to show exactly how much of cloud services was actually billed vs total consumed daily. Surface this in FinOps dashboard.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact 1: Native App Daily Cost Attribution SQL

```sql
-- Query to track daily cost per Native App in an organization
-- Assumes ACCOUNTADMIN or ORGADMIN role with access to ORGANIZATION_USAGE

SELECT 
    DATE_TRUNC('DAY', USAGE_DATE) AS cost_date,
    ORGANIZATION_NAME,
    ACCOUNT_NAME,
    APPLICATION_NAME,
    SERVICE_TYPE,
    SUM(CREDITS_USED) AS total_credits,
    -- Estimated cost assuming $2.00/credit (varies by account type + region)
    SUM(CREDITS_USED) * 2.00 AS estimated_cost_usd
FROM SNOWFLAKE.ORGANIZATION_USAGE.APPLICATION_DAILY_USAGE_HISTORY
WHERE USAGE_DATE >= DATEADD(DAY, -30, CURRENT_DATE())
GROUP BY 1, 2, 3, 4, 5
ORDER BY total_credits DESC;
```

### Artifact 2: Compute Pool Cost with Node Scaling Analysis

```sql
-- Tracks SPCS compute pool cost and node utilization
-- Useful for identifying over-provisioned pools

WITH pool_usage AS (
    SELECT 
        POOL_NAME,
        ACCOUNT_NAME,
        NODE_TYPE,
        MIN(MIN_NODES) AS min_nodes_configured,
        MAX(MAX_NODES) AS max_nodes_configured,
        AVG(CURRENT_NODES) AS avg_nodes_running,
        MAX(CURRENT_NODES) AS peak_nodes
    FROM SNOWFLAKE.ORGANIZATION_USAGE.COMPUTE_POOLS
    WHERE DATE_TRUNC('DAY', TIMESTAMP) >= CURRENT_DATE() - 7
    GROUP BY POOL_NAME, ACCOUNT_NAME, NODE_TYPE
)
SELECT 
    p.*,
    -- Estimate hourly cost (credit rates vary by machine type)
    -- CPU-XSMALL = 1 credit/hour per node, GPU-SMALL = 8 credits/hour per node
    CASE 
        WHEN NODE_TYPE LIKE 'GPU%' THEN p.peak_nodes * 8
        ELSE p.peak_nodes * 1
    END AS est_peak_credits_per_hour,
    -- Utilization ratio: actual vs max capacity
    ROUND(avg_nodes_running / NULLIF(max_nodes_configured, 0), 2) AS utilization_ratio,
    -- Flag over-provisioned pools
    CASE 
        WHEN avg_nodes_running < min_nodes_configured * 0.5 THEN 'OVER_PROVISIONED'
        WHEN avg_nodes_running > max_nodes_configured * 0.8 THEN 'NEAR_LIMIT'
        ELSE 'HEALTHY'
    END AS provisioning_status
FROM pool_usage p
ORDER BY est_peak_credits_per_hour DESC;
```

### Artifact 3: Cloud Services Billed vs Raw Consumed (Reconciliation)

```sql
-- Reconciles raw consumed vs billed credits for cloud services
-- Critical for accurate invoicing/tenant billing

SELECT 
    USAGE_DATE,
    ORGANIZATION_NAME,
    ACCOUNT_NAME,
    WAREHOUSE_CREDITS_USED,
    CLOUD_SERVICES_CREDITS_USED,
    -- The adjustment applied (negative if under 10% threshold)
    CLOUD_SERVICES_CREDITS_ADJUSTMENT,
    -- Actual billed = consumed + adjustment
    (WAREHOUSE_CREDITS_USED + CLOUD_SERVICES_CREDITS_USED + CLOUD_SERVICES_CREDITS_ADJUSTMENT) AS total_billed_credits,
    -- Threshold calculation
    (CLOUD_SERVICES_CREDITS_USED / NULLIF(WAREHOUSE_CREDITS_USED, 0)) * 100 AS cloud_services_pct_of_warehouse
FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD(DAY, -7, CURRENT_DATE())
ORDER BY total_billed_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `APPLICATION_DAILY_USAGE_HISTORY` shows total consumption, not billed credits (cloud services adjustment happens at billing level) | High - dashboards may show inflated costs | Cross-reference with `METERING_DAILY_HISTORY.CLOUD_SERVICES_ADJUSTMENT` |
| SPCS Compute Pool credit rates are not documented in `ORGANIZATION_USAGE` views - need external rate card reference | Medium - cost estimates may be inaccurate | Align with Snowflake Service Consumption Table (PDF) |
| Tagging requires pre-existing resource tagging strategy; untagged resources can't be attributed | Medium - incomplete cost visibility | Require tagging policy for new Native App deployments |
| GPU machine types have variable pricing depending on region/cloud provider | Medium - projections vary by deployment | Validate rates per region using `USAGE_IN_CURRENCY_DAILY` |
| ORG_USAGE views require ACCOUNTADMIN/ORGADMIN role - consumers may not have access | High - limited observability for tenants | Build proxy views or expose cost data to consumer via app_pre-created views |
| Per-second billing with 60s minimum means short-lived operations (e.g., queries < 60s) get charged for full minute | Low - query optimization can reduce minutes, not seconds | Optimize for long-running batch jobs rather than ad-hoc queries |

## Links & Citations

1. [Understanding overall cost | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/cost-understanding-overall) - Overview of Snowflake cost model (compute, storage, data transfer) with total cost examples

2. [Understanding compute cost | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/cost-understanding-compute) - Deep dive on credit consumption for warehouses, serverless, compute pools, and cloud services including the 10% adjustment rule

3. [Exploring compute cost | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/cost-exploring-compute) - Snowsight dashboards + query patterns for ACCOUNT_USAGE/ORGANIZATION_USAGE views, `APPLICATION_DAILY_USAGE_HISTORY` structure

4. [Snowpark Container Services | Snowflake Documentation](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview) - Compute pools architecture, node types (CPU/GPU), auto-scaling behavior, credit consumption model for SPCS

5. [Snowflake Service Consumption Table (PDF)](https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf) - Authoritative credit rates per warehouse size, serverless features, and compute pool node types (external reference)

## Next Steps / Follow-ups

-
