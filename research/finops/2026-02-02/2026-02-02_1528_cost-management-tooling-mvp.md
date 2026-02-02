# FinOps Research Note — Snowflake cost management primitives (docs scan) → Native App MVP hooks

- **When (UTC):** 2026-02-02 15:28
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** Our FinOps Native App needs a **stable, low-privilege telemetry layer** and a set of **actionable levers** (warehouse tuning, monitoring, showback) that map cleanly to Snowflake’s documented cost-management capabilities.

## Accurate takeaways
- Snowflake’s cost optimization guidance is organized around **visibility + controls + ongoing optimization** (i.e., measure first, then act).
- Documented levers heavily emphasize **warehouse configuration and usage patterns** (e.g., rightsizing, auto-suspend/resume, avoiding idle) as core control points for compute spend.
- Snowflake positions cost management as a combination of: (a) understanding the **billing model layers** (storage, serverless features, cloud services) and (b) using platform features + operational best practices to reduce waste.

## Snowflake objects & data sources (verify in target account)
- **ACCOUNT_USAGE** (commonly used for FinOps automation; latency applies):
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` — warehouse compute metering (hourly granularity); foundational for showback.
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` — query workload dimensions (user/role/warehouse/database/schema/query tags) for attribution joins.
  - (If enabled/available) `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` — per-query compute cost attribution (credits).
  - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` — tag relationships for cost-center attribution.
- **Control-plane objects** (action surface):
  - Warehouses (`SHOW WAREHOUSES` / `ALTER WAREHOUSE …`) — size, auto-suspend, max cluster count, etc.
  - Resource monitors (`SHOW RESOURCE MONITORS`) — for warehouse-based spend controls/alerts.

## MVP features unlocked (PR-sized)
1) **Warehouse idle-cost leaderboard**
   - Compute daily (or hourly) “metered credits vs. query-active time proxy” per warehouse.
   - Flag warehouses likely wasting credits due to insufficient auto-suspend or chatty keep-alives.
2) **Rightsizing suggestions (config diff)**
   - For each warehouse: recommend auto-suspend threshold, scaling policy, min/max cluster bounds based on utilization + queueing proxies.
3) **Showback by cost-center tag (v1)**
   - Attribute query costs to `QUERY_TAG` / object tags (via `TAG_REFERENCES`) and roll up by day/week/month.

## Heuristics / detection logic (v1)
- **Idle waste (warehouse-level):**
  - `idle_credits ≈ warehouse_credits - sum(query_credits_assigned_to_wh)` (if `QUERY_ATTRIBUTION_HISTORY` available)
  - Otherwise use a proxy: `active_seconds` from `QUERY_HISTORY` (per warehouse/hour) vs metered credits for that hour.
- **Auto-suspend suggestion:**
  - If a warehouse has many short bursts, recommend a **lower** auto-suspend (e.g., 60s–300s) *unless* resume latency is unacceptable.
- **Spiky usage:**
  - Detect large hour-over-hour credit deltas; correlate with top queries/users/roles for explanation.

## Concrete artifact — v1 SQL draft (daily warehouse credits + showback scaffold)
> Goal: a minimal mart the Native App can materialize in its own schema for dashboards + alerts.

```sql
-- Create a daily warehouse cost table (credits) from ACCOUNT_USAGE.
-- NOTE: validate columns in target account; ACCOUNT_USAGE view schemas can evolve.

create or replace view FINOPS_MART.V_WAREHOUSE_CREDITS_DAILY as
select
  to_date(start_time)                              as usage_date,
  warehouse_name,
  sum(credits_used)                                as credits_used,
  min(start_time)                                  as first_hour_start,
  max(end_time)                                    as last_hour_end
from snowflake.account_usage.warehouse_metering_history
where start_time >= dateadd('day', -90, current_timestamp())
group by 1, 2;

-- Optional: scaffold for showback by QUERY_TAG (requires per-query credits).
-- If QUERY_ATTRIBUTION_HISTORY exists, use it; otherwise this view should be disabled.
create or replace view FINOPS_MART.V_QUERY_CREDITS_DAILY_BY_TAG as
select
  to_date(qah.start_time)                           as usage_date,
  coalesce(nullif(qh.query_tag, ''), '∅')          as query_tag,
  qh.warehouse_name,
  sum(qah.credits_used_compute)                     as credits_used_compute
from snowflake.account_usage.query_attribution_history qah
join snowflake.account_usage.query_history qh
  on qah.query_id = qh.query_id
where qah.start_time >= dateadd('day', -90, current_timestamp())
group by 1,2,3;
```

## Security/RBAC notes
- Native App should prefer **read-only access** to `SNOWFLAKE.ACCOUNT_USAGE` views + minimal grants to create its own schema/tables/views.
- Any “action” features (e.g., `ALTER WAREHOUSE`, resource monitor creation) must be **explicitly opt-in** (separate role) with clear blast-radius UI.

## Risks / assumptions
- Assumption: `ACCOUNT_USAGE` views are available and sufficiently complete in the customer account; we must handle **latency (hours)** and partial refresh.
- `QUERY_ATTRIBUTION_HISTORY` availability may vary; we need a feature flag and fallback heuristics.
- Warehouse metering is not the whole bill (serverless, storage, cloud services); this note focuses on the **warehouse-centric MVP**.

## Links / references
- Snowflake docs: Managing cost in Snowflake — https://docs.snowflake.com/en/user-guide/cost-management-overview
- Snowflake docs: Optimizing cost — https://docs.snowflake.com/en/user-guide/cost-optimize
- Snowflake Well-Architected Framework (Cost Optimization & FinOps) — https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
