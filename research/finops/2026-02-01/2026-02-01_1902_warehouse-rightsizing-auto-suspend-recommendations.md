# FinOps Research Note — Warehouse right-sizing + auto-suspend recommendations (v1)

- **When (UTC):** 2026-02-01 19:02
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** Warehouses are usually the dominant, most volatile cost driver. A FinOps Native App can continuously detect (1) configuration drift (auto-suspend disabled / too high), (2) concurrency misconfigurations (multi-cluster overscaling), and (3) chronic over/under-sizing using telemetry, then generate concrete “change requests” (with projected credit impact) and governance guardrails.

## Accurate takeaways
- Snowflake warehouses are billed **per-second** with a **60-second minimum each time a warehouse starts**; this makes aggressive auto-suspend viable but also introduces a “thrash” tradeoff if suspend/resume happens too frequently. \[Snowflake warehouses overview\]
- Snowflake explicitly recommends setting **auto-suspend to a low value (e.g., 5–10 minutes or less)**, but warns that if your workload has short gaps, setting it too low can cause frequent suspend/resume and you’ll incur the 60-second minimum each time. \[Warehouse considerations\]
- For multi-cluster warehouses, **auto-suspend only happens when the minimum cluster count is running** and the warehouse is idle; auto-resume only applies when the *entire* warehouse is suspended. \[Snowflake warehouses overview\]
- Snowflake positions **object tags** (warehouses/users/etc.) + **query tags** as the core primitives for cost attribution; for SQL-based showback/chargeback they recommend joining `TAG_REFERENCES` with `WAREHOUSE_METERING_HISTORY` and using `QUERY_ATTRIBUTION_HISTORY` for query-level compute cost attribution (excluding idle time). \[Attributing cost\]
- Snowflake’s own cost optimization guidance highlights that auto-suspend can be disabled; therefore you should **monitor/guardrail auto-suspend configuration** and restrict who can change it. \[Well-Architected: Cost Optimization\]

## Snowflake objects & data sources (verify in target account)
- **Warehouse configuration state**
  - `SHOW WAREHOUSES` (operational, point-in-time; easiest for an app to query, but not historical)
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES` (historical-ish catalog view; verify columns like `AUTO_SUSPEND`, `MIN_CLUSTER_COUNT`, `MAX_CLUSTER_COUNT`, `SCALING_POLICY`, `WAREHOUSE_TYPE`, `RESOURCE_CONSTRAINT` in your target account)
- **Compute consumption**
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (credit usage by warehouse over time) \[Attributing cost\]
  - Optional: `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY` (queue/running metrics; referenced by Snowflake as useful for consolidation decisions) \[Well-Architected: Cost Optimization\]
- **Query-level cost and attribution**
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute credit attribution; excludes idle time; no org-wide equivalent) \[Attributing cost\]
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (telemetry for duration, bytes scanned, warehouse, etc.; used in Snowflake cost optimization guidance) \[Well-Architected: Cost Optimization\]
- **Tagging / cost-center mapping**
  - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (object-to-tag mapping) \[Attributing cost\]

## MVP features unlocked (PR-sized)
1) **“Auto-suspend drift” detector + fix script generator**
   - Detect warehouses with `AUTO_SUSPEND IS NULL/0` (disabled) or > threshold (e.g., > 600s) and propose `ALTER WAREHOUSE ... SET AUTO_SUSPEND = <n>`.
2) **Multi-cluster overspend risk detector**
   - Identify multi-cluster warehouses where `MAX_CLUSTER_COUNT` is large relative to observed concurrency and propose smaller max (plus evidence).
3) **Right-sizing candidates (downsize / consolidate) report**
   - Use `WAREHOUSE_METERING_HISTORY` + `WAREHOUSE_LOAD_HISTORY` to flag warehouses with low “busy ratio” and minimal queuing, suggesting downsizing or consolidation.

## Heuristics / detection logic (v1)
- **Auto-suspend too high / disabled**
  - If `AUTO_SUSPEND` is `NULL` or `0` → critical finding (warehouse can burn credits while idle).
  - If `AUTO_SUSPEND` > 600s (10m) → warning; show how often the warehouse is actually idle vs active to contextualize.
  - If `AUTO_SUSPEND` < 60s → warn about potential thrash given the 60s minimum billing per start; recommend validating against gap distribution between queries. \[Snowflake warehouses overview\] \[Warehouse considerations\]
- **Multi-cluster configuration sanity**
  - Prefer `SCALING_POLICY = 'STANDARD'/'ECONOMY'` (account-specific values) with Auto-scale mode unless a specific requirement exists; Snowflake warns to be mindful that large `MAX_CLUSTER_COUNT` can multiply credits linearly with clusters. \[Warehouse considerations\]
- **Idle cost framing**
  - `QUERY_ATTRIBUTION_HISTORY` explicitly excludes idle time; to estimate “idle credits”, compare `WAREHOUSE_METERING_HISTORY` (total credits) vs sum of query-attributed credits. The remainder is *likely* idle + non-attributed overhead (validate). \[Attributing cost\]

## Security/RBAC notes
- A Native App typically needs a clear RBAC story for reading `SNOWFLAKE.ACCOUNT_USAGE` views (often gated behind `MONITOR USAGE` / imported privileges depending on packaging). Confirm minimum required privileges and document them in the app’s install-time checklist.
- If the app proposes configuration changes (e.g., `ALTER WAREHOUSE`), treat it as **advisory by default**: generate SQL for an admin to review/run, or implement an opt-in “apply changes” capability with explicit privileged roles.

## Risks / assumptions
- **Column availability differs** by edition/region and over time (Gen2 warehouses, `RESOURCE_CONSTRAINT`, scaling policy names). Queries must be defensive.
- `ACCOUNT_USAGE` views have known latency vs real-time; near-real-time alerts may need `INFORMATION_SCHEMA` or event/telemetry alternatives.
- Estimating “idle credits” as (metered - attributed) is conceptually useful, but may include other non-query-attributed compute drivers; validate with Snowflake’s definitions in the target environment.

## Concrete artifact — SQL draft (v1)

### 1) Warehouse configuration drift (auto-suspend + multi-cluster risk)
```sql
-- Purpose: identify warehouses likely to waste credits due to configuration.
-- Data sources: ACCOUNT_USAGE.WAREHOUSES (if available) + SHOW WAREHOUSES fallback.
-- NOTE: verify column names in your account.

with wh as (
  select
    warehouse_id,
    name as warehouse_name,
    auto_suspend,
    auto_resume,
    min_cluster_count,
    max_cluster_count,
    scaling_policy,
    warehouse_type,
    resource_constraint,
    created_on,
    last_altered
  from snowflake.account_usage.warehouses
  qualify row_number() over (partition by warehouse_id order by last_altered desc) = 1
)
select
  warehouse_name,
  auto_suspend,
  case
    when auto_suspend is null or auto_suspend = 0 then 'CRITICAL: auto-suspend disabled'
    when auto_suspend > 600 then 'WARN: auto-suspend > 10m'
    when auto_suspend < 60 then 'WARN: auto-suspend < 60s (thrash risk w/ 60s min billing)'
    else 'OK'
  end as autosuspend_finding,
  min_cluster_count,
  max_cluster_count,
  case
    when coalesce(max_cluster_count, 1) >= 10 then 'WARN: high max clusters; verify concurrency need'
    else 'OK'
  end as multicluster_finding,
  scaling_policy,
  warehouse_type,
  resource_constraint,
  last_altered
from wh
order by autosuspend_finding desc, multicluster_finding desc, warehouse_name;
```

### 2) “Idle credits” estimate per warehouse (metered vs attributed)
```sql
-- Purpose: approximate idle credit spend by warehouse for a time window.
-- Rationale: QUERY_ATTRIBUTION_HISTORY excludes idle time; metering includes total.

set start_ts = dateadd('day', -7, current_timestamp());
set end_ts   = current_timestamp();

with metered as (
  select
    warehouse_id,
    sum(credits_used) as credits_metered
  from snowflake.account_usage.warehouse_metering_history
  where start_time >= $start_ts and start_time < $end_ts
  group by 1
),
attributed as (
  select
    warehouse_id,
    sum(credits_attributed_compute) as credits_attributed
  from snowflake.account_usage.query_attribution_history
  where start_time >= $start_ts and start_time < $end_ts
  group by 1
)
select
  coalesce(m.warehouse_id, a.warehouse_id) as warehouse_id,
  m.credits_metered,
  a.credits_attributed,
  (m.credits_metered - a.credits_attributed) as credits_unattributed_est_idle,
  iff(m.credits_metered = 0, null,
      (m.credits_metered - a.credits_attributed) / m.credits_metered) as pct_unattributed
from metered m
full outer join attributed a using (warehouse_id)
order by credits_unattributed_est_idle desc nulls last;
```

## Links / references
- https://docs.snowflake.com/en/user-guide/warehouses-overview
- https://docs.snowflake.com/en/user-guide/warehouses-considerations
- https://docs.snowflake.com/en/user-guide/cost-attributing
- https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
