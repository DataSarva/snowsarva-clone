# FinOps Research Note — Cost observability foundations: tags + per-query attribution (Snowflake)

- **When (UTC):** 2026-02-02 01:09
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs a stable, low-friction way to (a) explain spend (“who/what caused it?”) and (b) drive action (tag hygiene, showback/chargeback, anomaly detection). Snowflake’s newer per-query attribution + tag-based attribution unlocks credible unit economics without building an expensive custom attribution engine.

## Accurate takeaways
- Snowflake’s recommended approach for showback/chargeback is **tags + (optionally) query tags**:
  - **Object tags** can be applied to resources (e.g., warehouses) and principals (e.g., users) to represent cost centers/projects.
  - **Query tags** can be set at session level to attribute queries issued “on behalf of” many users (application / workflow scenario). [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
- Within a single account, Snowflake documentation explicitly calls out using **ACCOUNT_USAGE** views to attribute costs:
  - `ACCOUNT_USAGE.TAG_REFERENCES`
  - `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`
  - `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (compute costs per query for warehouse usage). [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
- `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query warehouse compute costs** for the last 365 days, with important caveats:
  - Excludes: data transfer, storage, cloud services, serverless, AI token costs, etc.
  - For concurrent queries, costs are allocated based on weighted average resource consumption over an interval.
  - **Does not include warehouse idle time**; very short-running queries (≈<=100ms) may be excluded. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- Snowflake’s “Exploring compute cost” guidance frames total compute as: **warehouses + serverless + cloud services (+ certain Openflow runtimes)**, and highlights that usage views can be queried via **ACCOUNT_USAGE/ORGANIZATION_USAGE** for custom reporting.
  - To convert credits → currency at org scope, use `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` (daily). [https://docs.snowflake.com/en/user-guide/cost-exploring-compute](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)
- Organization-wide limitation: the docs state there is **no organization-wide equivalent** of `QUERY_ATTRIBUTION_HISTORY`; it’s **account-scoped** in `ACCOUNT_USAGE`. [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)

## Snowflake objects & data sources (verify in target account)
Primary (account-scoped):
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` — per-query warehouse compute cost (credits). [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` — warehouse credit usage (hourly-ish granularity depending on view). (Referenced as a key join source for tagged warehouse showback.) [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
- `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` — mapping of tags to objects/users (for showback dimensions). [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)

Supporting (org / currency):
- `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` — daily credits + currency cost using daily price of a credit. [https://docs.snowflake.com/en/user-guide/cost-exploring-compute](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)

## MVP features unlocked (PR-sized)
1) **“Cost Attribution Baseline” dashboard** (account-scoped):
   - Monthly cost by `warehouse` tag (dedicated warehouses) and by `user` tag (shared warehouses), using `TAG_REFERENCES` + `WAREHOUSE_METERING_HISTORY` / `QUERY_ATTRIBUTION_HISTORY`.
2) **Idle-time visibility + fairness knobs** (account-scoped):
   - Compute *idle credits* per warehouse = metered warehouse credits − sum(per-query credits), then distribute idle credits proportionally to query-attributed credits for showback (optional toggle).
3) **Tag hygiene report**:
   - % of warehouse credits attributable to a valid cost_center tag vs “unattributed”; list top untagged warehouses/users by credits.

## Heuristics / detection logic (v1)
- **Unattributed spend**
  - Warehouses: warehouse metering rows with no `TAG_REFERENCES` hit for chosen tag key.
  - Users: query-attribution rows where user tag is missing (or query tag missing for app-style attribution).
- **Idle-time waste candidates**
  - Warehouses with high (metered credits − per-query credits) over a window.
  - Flag if idle credits exceed threshold absolute (e.g., > X credits/day) or relative (e.g., > Y% of warehouse metered credits).
- **Per-query heavy hitters**
  - Group by `query_hash` / `query_parameterized_hash` (called out as a recommended way to group recurring queries for cost analysis). [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)

## Concrete artifact: SQL draft (v1)
Goal: monthly showback by a `COST_CENTER` tag on **users**, including optional idle-time allocation.

Assumptions (explicit):
- The account uses a single “billing currency” but we treat currency conversion separately (org view is daily).
- `QUERY_ATTRIBUTION_HISTORY` has columns needed to join to users and warehouses; confirm exact column names in your account (the view definition is authoritative).
- `WAREHOUSE_METERING_HISTORY` time grain is compatible with monthly rollups; for v1, monthly aggregation avoids time-bucket alignment issues.

```sql
-- v1: monthly cost attribution by user tag (COST_CENTER)
--      (a) direct per-query credits (no idle time)
--      (b) optional idle-time allocation by proportional usage

set TAG_NAME = 'COST_CENTER';

with user_tags as (
  select
    object_id           as user_id,
    tag_name,
    tag_value
  from snowflake.account_usage.tag_references
  where domain = 'USER'
    and tag_name = $TAG_NAME
),
query_cost as (
  select
    date_trunc('month', start_time) as month,
    warehouse_id,
    user_name,               -- confirm column name; some accounts may need user_id mapping
    query_id,
    credits_attributed_compute as query_credits  -- confirm column name in view
  from snowflake.account_usage.query_attribution_history
  where start_time >= dateadd('month', -12, current_timestamp())
),
query_cost_with_tags as (
  select
    qc.month,
    coalesce(ut.tag_value, 'UNATTRIBUTED') as cost_center,
    sum(qc.query_credits) as query_credits
  from query_cost qc
  left join user_tags ut
    on ut.user_id = qc.user_name  -- v1 placeholder; in practice join via USER_ID if available
  group by 1, 2
),
warehouse_metered as (
  select
    date_trunc('month', start_time) as month,
    warehouse_id,
    sum(credits_used) as metered_credits
  from snowflake.account_usage.warehouse_metering_history
  where start_time >= dateadd('month', -12, current_timestamp())
  group by 1, 2
),
warehouse_query_sum as (
  select
    month,
    warehouse_id,
    sum(query_credits) as query_credits
  from (
    select
      date_trunc('month', start_time) as month,
      warehouse_id,
      credits_attributed_compute as query_credits
    from snowflake.account_usage.query_attribution_history
    where start_time >= dateadd('month', -12, current_timestamp())
  )
  group by 1, 2
),
warehouse_idle as (
  select
    wm.month,
    wm.warehouse_id,
    greatest(wm.metered_credits - coalesce(wqs.query_credits, 0), 0) as idle_credits
  from warehouse_metered wm
  left join warehouse_query_sum wqs
    on wqs.month = wm.month and wqs.warehouse_id = wm.warehouse_id
),
-- Allocate idle credits to cost_centers proportionally to their query credits in that warehouse/month.
allocated_idle as (
  select
    qc.month,
    qc.warehouse_id,
    coalesce(ut.tag_value, 'UNATTRIBUTED') as cost_center,
    sum(qc.query_credits) as query_credits,
    -- proportional allocation
    (sum(qc.query_credits) / nullif(sum(sum(qc.query_credits)) over (partition by qc.month, qc.warehouse_id), 0))
      * wi.idle_credits as idle_credits_allocated
  from query_cost qc
  left join user_tags ut
    on ut.user_id = qc.user_name  -- v1 placeholder
  join warehouse_idle wi
    on wi.month = qc.month and wi.warehouse_id = qc.warehouse_id
  group by 1, 2, 3, wi.idle_credits
)
select
  month,
  cost_center,
  query_credits,
  idle_credits_allocated,
  query_credits + idle_credits_allocated as total_credits_including_idle
from allocated_idle
order by month desc, total_credits_including_idle desc;
```

What this unlocks in the app:
- A deterministic “credits ledger” per cost center per month, with an explicit switch for whether idle is included.

## Security/RBAC notes
- Snowsight cost dashboards require a role with access to cost and usage data; the FinOps Native App will need a similarly scoped model (likely a dedicated “app reader” role granted access to `SNOWFLAKE.ACCOUNT_USAGE` and/or views shared into an app-owned database).
  - Exact grants need validation for Native App packaging + consumer account model.

## Risks / assumptions
- Column names and join keys in `QUERY_ATTRIBUTION_HISTORY` may differ from the placeholders above; need to confirm exact schema in a target account.
- Per-query attribution excludes short queries and idle time; dashboards must message this clearly to avoid “why doesn’t it sum?” confusion. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- Org-wide rollups: there is no org-wide `QUERY_ATTRIBUTION_HISTORY`, so cross-account per-query chargeback requires either per-account collection or accepting coarser org-level metering views. [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)

## Links / references
- Snowflake Docs: Attributing cost — tags, query tags, and the key ACCOUNT_USAGE views. [https://docs.snowflake.com/en/user-guide/cost-attributing](https://docs.snowflake.com/en/user-guide/cost-attributing)
- Snowflake Docs: QUERY_ATTRIBUTION_HISTORY — per-query compute cost caveats and usage. [https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- Snowflake Docs: Exploring compute cost — ACCOUNT_USAGE/ORGANIZATION_USAGE + currency conversion view. [https://docs.snowflake.com/en/user-guide/cost-exploring-compute](https://docs.snowflake.com/en/user-guide/cost-exploring-compute)
- Snowflake Release Note: Query attribution costs (introducing the view). [https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution](https://docs.snowflake.com/en/release-notes/2024/other/2024-08-30-per-query-cost-attribution)
