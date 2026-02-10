# Research: FinOps - 2026-02-09

**Time:** 23:10 UTC  
**Topic:** Snowflake FinOps Cost Optimization — Auto-suspend/auto-resume, minimum billing, and guardrails  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake virtual warehouses are billed **per-second** while running, but each time a warehouse is **started or resumed** there is a **60-second minimum charge**; suspending and resuming again within that first minute can trigger **multiple 60-second minimum charges**. (Understanding compute cost)  
2. Setting `AUTO_SUSPEND` too low relative to natural gaps between queries can cause a warehouse to “thrash” (frequent suspend/resume) and repeatedly re-trigger the **60-second minimum**, increasing effective cost for short, bursty workloads. Snowflake explicitly recommends aligning the auto-suspend value to workload gaps and notes the repeated-minimum-billing effect. (Warehouse considerations)
3. A running warehouse maintains a **data cache** of accessed table data, and that cache is **dropped when the warehouse suspends**, which can make the first queries after resumption slower. This creates a cost/perf trade-off: lower idle spend vs. cache warmth. (Warehouse considerations)
4. Snowflake recommends controlling warehouse cost by combining: (a) **access controls** (e.g., restrict who can `CREATE WAREHOUSE` and who can `MODIFY` settings like size and `AUTO_SUSPEND`), (b) **timeouts** for runaway queries/queueing, (c) **auto-suspend/auto-resume**, and (d) **resource monitors** to enforce quotas and suspend warehouses when thresholds are reached. (Cost controls for warehouses)
5. **Resource monitors** track credits consumed by assigned warehouses **plus** supporting cloud services credits, can reset on an interval (daily/weekly/monthly/etc.), and can trigger actions such as **Notify**, **Notify & Suspend**, or **Notify & Suspend Immediately**. Snowflake notes monitors are interval guardrails (not precise hourly caps) and recommends buffers (e.g., suspend at 90%) because suspension can take time and consume extra credits. (Working with resource monitors)
6. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` contains warehouse/cluster events including **resume/suspend** (and multi-cluster spin-up/spin-down), which is sufficient to reconstruct **run cycles** and quantify restart-churn patterns that drive minimum-billing overhead. (WAREHOUSE_EVENTS_HISTORY view)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY` | View | Snowflake docs | Warehouse + cluster lifecycle events (resume/suspend, resize, etc.). Use to build resume→suspend cycles and “restart churn” metrics. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | Snowflake docs | Hourly credits by warehouse (compute + cloud services). Use for attribution and validation of estimates. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY` | View | Snowflake docs | Load signals (`AVG_RUNNING`, queued load, queued provisioning) to diagnose concurrency/underprovisioning. |
| `SHOW WAREHOUSES` | Command | Snowflake docs | Source of configuration state (e.g., `auto_suspend`, `auto_resume`, `resource_monitor`). Can be snapshot into a table for app analysis. |
| `SHOW RESOURCE MONITORS` / `CREATE RESOURCE MONITOR` | Commands | Snowflake docs | Guardrail config, quotas, and actions. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Restart-churn detector (minimum billing overhead):** daily score per warehouse that estimates credits lost to the 60-second minimum due to frequent resume/suspend cycles.
2. **Auto-suspend recommender:** for each warehouse, recommend a candidate `AUTO_SUSPEND` based on observed cycle durations and suspend/resume frequency (with a cache-warmth warning if workload benefits from cache).
3. **Guardrail compliance checks:** scheduled checks that flag (a) warehouses with `AUTO_SUSPEND` disabled, (b) `AUTO_RESUME` disabled, and (c) warehouses not covered by any warehouse-level monitor (or not covered by an account monitor).
4. **Resource monitor policy templates:** generate suggested resource monitor definitions (quota, frequency, thresholds) and optionally automate assignment (where privileges allow).

## Concrete Artifacts

### SQL Draft: `FINOPS.WAREHOUSE_MIN_BILLING_OVERHEAD_DAILY`

*Purpose:* Estimate how much compute spend is attributable to the **60-second minimum** caused by frequent resume/suspend, using `WAREHOUSE_EVENTS_HISTORY`.

Notes/limitations:
- Uses a **credits/hour mapping** for standard warehouse sizes; validate for your edition/region and for **Snowpark-optimized** warehouses (which can have different consumption; see the Service Consumption Table).
- Pairs each **resume** event to the next **suspend** event for the same warehouse + cluster.

```sql
CREATE OR REPLACE VIEW FINOPS.WAREHOUSE_MIN_BILLING_OVERHEAD_DAILY AS
WITH events AS (
  SELECT
    timestamp                                     AS event_ts,
    warehouse_name,
    COALESCE(cluster_number, 1)                   AS cluster_number,
    event_name,
    size,
    CASE
      WHEN event_name IN ('RESUME_WAREHOUSE','RESUME_CLUSTER') THEN 'RESUME'
      WHEN event_name IN ('SUSPEND_WAREHOUSE','SUSPEND_CLUSTER') THEN 'SUSPEND'
      ELSE NULL
    END                                           AS event_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE event_name IN ('RESUME_WAREHOUSE','SUSPEND_WAREHOUSE','RESUME_CLUSTER','SUSPEND_CLUSTER')
),
resume_to_suspend AS (
  SELECT
    warehouse_name,
    cluster_number,
    event_ts                                      AS resume_ts,
    LEAD(event_ts)  OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_ts,
    LEAD(event_type) OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_type,
    size
  FROM events
  WHERE event_type = 'RESUME'
),
cycles AS (
  SELECT
    warehouse_name,
    cluster_number,
    resume_ts,
    next_ts                                       AS suspend_ts,
    DATEDIFF('second', resume_ts, next_ts)        AS run_seconds,
    GREATEST(DATEDIFF('second', resume_ts, next_ts), 60) AS billed_seconds,
    /* Standard warehouse credits/hour (per cluster) — validate for your account. */
    CASE UPPER(REPLACE(size,'-',''))
      WHEN 'XSMALL'  THEN 1
      WHEN 'SMALL'   THEN 2
      WHEN 'MEDIUM'  THEN 4
      WHEN 'LARGE'   THEN 8
      WHEN 'XLARGE'  THEN 16
      WHEN '2XLARGE' THEN 32
      WHEN '3XLARGE' THEN 64
      WHEN '4XLARGE' THEN 128
      WHEN '5XLARGE' THEN 256
      WHEN '6XLARGE' THEN 512
      ELSE NULL
    END                                           AS credits_per_hour
  FROM resume_to_suspend
  WHERE next_type = 'SUSPEND'
    AND next_ts IS NOT NULL
    AND DATEDIFF('second', resume_ts, next_ts) >= 0
)
SELECT
  DATE_TRUNC('day', resume_ts)                    AS day,
  warehouse_name,
  COUNT(*)                                        AS resume_cycles,
  SUM(run_seconds)                                AS total_run_seconds,
  SUM(billed_seconds - run_seconds)               AS min_bill_overhead_seconds,
  /* Estimated credits (compute) */
  SUM((billed_seconds / 3600.0) * credits_per_hour) AS est_credits_total,
  SUM(((billed_seconds - run_seconds) / 3600.0) * credits_per_hour) AS est_credits_min_bill_overhead,
  /* Heuristic: share of estimated credits that are overhead due to minimum billing */
  IFF(SUM((billed_seconds / 3600.0) * credits_per_hour) = 0,
      NULL,
      SUM(((billed_seconds - run_seconds) / 3600.0) * credits_per_hour)
      / SUM((billed_seconds / 3600.0) * credits_per_hour)
  ) AS overhead_ratio
FROM cycles
WHERE credits_per_hour IS NOT NULL
GROUP BY 1,2;
```

**How to use it in a FinOps app**
- Sort by `est_credits_min_bill_overhead` desc to find warehouses paying heavily for restart churn.
- For top offenders, check whether workload is bursty and consider:
  - increasing `AUTO_SUSPEND` (to span typical gaps),
  - batching short-running queries,
  - splitting “spiky” workloads into a dedicated small warehouse.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Credits/hour mapping is simplified and assumes standard warehouse sizing. | Over/under-estimation of overhead, especially for Snowpark-optimized warehouses. | Cross-check against `WAREHOUSE_METERING_HISTORY` totals; align mapping with the Service Consumption Table. |
| Event pairing (resume→suspend) can be disrupted by missing events or overlapping cluster behavior in multi-cluster. | Cycle duration estimates can be wrong. | Add additional event types (`SPINUP_CLUSTER`/`SPINDOWN_CLUSTER`) if present; validate on known warehouses. |
| Cache effects are workload-dependent. | Recommendations could hurt latency if cache warmth matters. | Include a “cache sensitivity” flag derived from query repetition / hot tables, or require opt-in for aggressive suspend. |
| Resource monitors include cloud services consumption (even if not billed due to the 10% adjustment). | Monitor-triggered suspensions may occur earlier than expected from invoice perspective. | Display both “monitor credits” and “billed credits” context in UI; cite Snowflake’s note. |

## Links & Citations

1. Understanding compute cost (per-second billing, 60-second minimum; start/resume/resize minimums): https://docs.snowflake.com/en/user-guide/cost-understanding-compute
2. Warehouse considerations (auto-suspend set relative to workload gaps; repeated minimum billing; cache dropped on suspend): https://docs.snowflake.com/en/user-guide/warehouses-considerations
3. Cost controls for warehouses (auto-suspend/auto-resume guidance and audit queries; access control; resource monitors): https://docs.snowflake.com/en/user-guide/cost-controlling-controls
4. Working with resource monitors (quota, actions incl. suspend immediate; buffers; cloud services treatment): https://docs.snowflake.com/en/user-guide/resource-monitors
5. WAREHOUSE_EVENTS_HISTORY view (resume/suspend and cluster events history): https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_events_history
6. Snowflake Service Consumption Table (authoritative credits/hour tables incl. special warehouse types): https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf

## Next Steps / Follow-ups

- Extend the churn view to include `SPINUP_CLUSTER` / `SPINDOWN_CLUSTER` to improve multi-cluster fidelity if those events appear in your account.
- Add a companion “configuration snapshot” table populated daily from `SHOW WAREHOUSES` to join `AUTO_SUSPEND`, `AUTO_RESUME`, `MIN/MAX_CLUSTER_COUNT`, and `RESOURCE_MONITOR` to churn/credit metrics.
- Prototype an `AUTO_SUSPEND` recommender that optimizes for: (a) low overhead ratio, (b) acceptable resume latency, and (c) cache sensitivity.