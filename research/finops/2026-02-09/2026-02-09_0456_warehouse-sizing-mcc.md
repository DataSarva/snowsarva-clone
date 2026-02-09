# Research: FinOps - Warehouse Sizing & Multi-Cluster Deep Dive
**Time:** 04:56 UTC
**Topic:** Snowflake Warehouse Sizing, Credit Metering, and Multi-Cluster Configuration
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways
*Plain statements validated from sources. No marketing language.*

1. **Gen1 Standard Warehouse Credit Consumption**: Credits per hour double with each size increment (X-Small=1, Small=2, Medium=4, Large=8, X-Large=16, 2X=32, 3X=64, 4X=128, 5X=256, 6X=512). Per-second billing with 60-second minimum per-run.

2. **Gen2 Standard Warehouses Available**: A newer generation focused on analytics/data engineering performance improvements. Not available for X5LARGE/X6LARGE. Gen2 is the default for new organizations in select regions (AWS US West, AWS EU Frankfurt, Azure East US 2, Azure West Europe) created after June 27, 2025; other regions default after July 15, 2025.

3. **Auto-suspend/Resume on Multi-Cluster**: Auto-suspend applies to the *entire* multi-cluster warehouse, not individual clusters. Clusters within an MCW start/stop based on load when in Auto-scale mode.

4. **Multi-Cluster Scaling Policies**: Two policies—`STANDARD` (aggressive scale-up, conservative scale-down) and `ECONOMY` (conservative scale-up, aggressive scale-down). Policy only affects Auto-scale mode.

5. **Maximum Clusters by Size**: Smaller warehouses allow more clusters (X-Small→3XL: up to 300 clusters; 4XL→6XL: up to 10 clusters). This inverse relationship matters for cost vs. concurrency trade-offs.

6. **Data Loading Performance**: Warehouse size has *diminishing returns* for data loading—number/sizing of files matters more than warehouse size. Small/Medium/Large generally sufficient unless loading hundreds/thousands of files concurrently.

7. **Warehouse Generation Switching Costs**: When converting Gen1→Gen2 (or standard→Snowpark-optimized) without suspending: in-flight queries continue on old resources while new queries use new resources—both billed simultaneously until old queries complete.

---

## Snowflake Objects & Data Sources
| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Credit consumption per warehouse per interval |
| WAREHOUSE_EVENTS_HISTORY | View | ACCOUNT_USAGE | Resize, suspend, resume events |
| WAREHOUSE_LOAD_HISTORY | View | ACCOUNT_USAGE | Load metrics for bulk operations |
| WAREHOUSE_SIZE | Column | SHOW WAREHOUSES / INFO_SCHEMA | Current size of warehouse |
| RESOURCE_CONSTRAINT | Column | SHOW WAREHOUSES | STANDARD_GEN_1, STANDARD_GEN_2, MEMORY_1X, etc. |
| SHOW WAREHOUSES | Command | System | Shows active warehouses including resource_constraint |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked
*PR-sized ideas that can be shipped based on these findings.*

1. **Warehouse Right-Sizing Advisor**: A Native App view that compares current warehouse sizes against actual query complexity and recommends size adjustments with projected credit savings.

2. **Multi-Cluster Cost Simulator**: SQL-based calculator that models MCW costs under different MIN/MAX/SIZING_POLICY configurations given historical concurrency patterns.

3. **Gen1→Gen2 Migration Tracker**: Automated detection of Gen1 warehouses and ROI analysis on switching to Gen2 based on workload type (heavy DML workloads benefit most).

---

## Concrete Artifacts
*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact A: Warehouse Cost Breakdown View (ACCOUNT_USAGE)
```sql
/*
Warehouse Cost Breakdown View
Shows per-warehouse credit consumption with cost estimates
Assumes $3.00/credit (adjust COST_PER_CREDIT for your contract)
*/
CREATE OR REPLACE VIEW WAREHOUSE_COST_BREAKDOWN AS
WITH credit_rates AS (
    -- Gen1 rates per hour per cluster
    SELECT * FROM (VALUES
        ('X-Small', 1.0),
        ('XSMALL', 1.0),
        ('Small', 2.0),
        ('Medium', 4.0),
        ('Large', 8.0),
        ('X-Large', 16.0),
        ('XLARGE', 16.0),
        ('2X-Large', 32.0),
        ('XXLARGE', 32.0),
        ('3X-Large', 64.0),
        ('XXXLARGE', 64.0),
        ('4X-Large', 128.0),
        ('X4LARGE', 128.0),
        ('5X-Large', 256.0),
        ('X5LARGE', 256.0),
        ('6X-Large', 512.0),
        ('X6LARGE', 512.0)
    ) AS t(size_name, credits_per_hour)
)
SELECT
    wm.warehouse_name,
    wm.warehouse_id,
    wm.start_time,
    wm.end_time,
    wm.credits_used,
    -- Cost estimate (adjust rate as needed)
    wm.credits_used * 3.00 AS estimated_cost_usd,
    datediff('minute', wm.start_time, wm.end_time) AS duration_minutes,
    -- Flag potential waste: auto-suspend threshold analysis
    CASE
        WHEN datediff('minute', wm.start_time, wm.end_time) <= 2 THEN 'SHORT_RUN_RISK'
        WHEN wm.credits_used < 0.1 THEN 'LOW_UTILIZATION_RISK'
        ELSE 'NORMAL'
    END AS utilization_flag
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wm;
```

### Artifact B: Multi-Cluster Warehouse Checklist

**Pre-Deployment Checklist:**

| Check | Rule | Impact |
|-------|------|--------|
| Size Selection | Smaller size + more clusters preferred for high concurrency, low per-query cost; larger size for single-query performance | Cost vs latency trade-off |
| MIN_CLUSTER_COUNT | Set based on minimum expected concurrent load; 1 for auto-scale start | Prevents cold start latency |
| MAX_CLUSTER_COUNT | Limit to `ceil(peak_concurrent_queries / avg_queries_per_cluster)` + buffer | Prevents runaway costs |
| SCALING_POLICY | `STANDARD` for latency-sensitive workloads; `ECONOMY` for batch/backfill | Scaling aggressiveness |
| AUTO_SUSPEND | Must be set and <30 min for non-production; can be NULL for always-on | Idle cost control |
| AUTO_RESUME | TRUE for user-facing warehouses; FALSE for scheduled-only ETL | Availability vs cost |

---

## Risks / Assumptions
| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Gen2 standard warehouses not yet available in all regions | Migration plans may be blocked | Check region availability in docs |
| Credit consumption rates are Gen1 baseline | Gen2 rates may differ; verify with CreditConsumptionTable.pdf from Snowflake legal | View credit table PDF |
| Per-second billing has 60s floor | Short queries (1-10s) are "over-billed" by ~6-60x | Awareness for micro-query patterns |
| Switching generations/type doubles billing temporarily | Cost spikes during migrations | Suspend first, or budget for overlap |
| INFORMATION_SCHEMA doesn't expose resource_constraint | SHOW WAREHOUSES required for Gen detection | Keep automation using SHOW command |

---

## Links & Citations
1. [Overview of warehouses | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/warehouses-overview)
2. [CREATE WAREHOUSE | Snowflake Documentation](https://docs.snowflake.com/en/sql-reference/sql/create-warehouse)
3. [Snowflake generation 2 standard warehouses](https://docs.snowflake.com/en/user-guide/warehouses-gen2)
4. [Multi-cluster warehouses](https://docs.snowflake.com/en/user-guide/warehouses-multicluster)
5. [Snowflake Service Consumption Table PDF](https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf)

---

## Next Steps / Follow-ups
- [ ] Fetch CreditConsumptionTable.pdf to verify Gen2 credit rates
- [ ] Research RESOURCE_MONITOR interactions with MCW
- [ ] Investigate QUERY_ACCELERATION feature behavior and billing
- [ ] Compile real cost data from ACCOUNT_USAGE for validation
- [ ] Create Native App stored procedure for right-sizing recommendations
