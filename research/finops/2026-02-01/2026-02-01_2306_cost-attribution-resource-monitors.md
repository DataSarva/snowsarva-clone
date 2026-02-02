# FinOps Research Note — Cost attribution + controls primitives (tags/query_tag + resource monitors) for a Snowflake FinOps Native App

- **When (UTC):** 2026-02-01 23:06
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs **durable, explainable attribution** (who/what drove spend) and **control surfaces** (alert/suspend) that admins already trust. Snowflake’s official guidance emphasizes **object tags + query tags** for attribution and **resource monitors** for credit controls; the app can productize these with opinionated schemas, detectors, and UX.

## Accurate takeaways
- Snowflake’s recommended approach for attributing costs to departments/projects is:
  - Use **object tags** to associate resources and users with logical cost units.
  - Use **query tags** to associate individual queries with departments/projects when an application submits queries on behalf of multiple groups.  
  Source: Snowflake docs “Attributing cost”.
- In the `SNOWFLAKE` database, `ACCOUNT_USAGE` contains account-level views for object metadata + historical usage metrics with retention/latency tradeoffs vs Information Schema. This is the core data surface most accounts can query for FinOps analytics.  
  Source: Snowflake docs “Account Usage”.
- `ORGANIZATION_USAGE` provides org-level views (notably with **~24 hour latency** for many views) for cross-account visibility, but some views are **premium** and only available in the organization account.  
  Source: Snowflake docs “Organization Usage”.
- **Resource monitors** are the built-in control to monitor credit usage and avoid unexpected spend; they can be configured to trigger actions such as suspending user-managed warehouses when thresholds are reached (details depend on configuration).  
  Source: Snowflake docs “Working with resource monitors”.
- Snowflake’s cost optimization guidance (Well-Architected) strongly reinforces: consistent tagging, showback/chargeback feedback loops, historical consumption insights, and anomaly investigation; this aligns directly with a “FinOps control plane” native app.
  Source: Snowflake Well-Architected cost optimization guide.

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE` (account-scoped historical views; latency varies by view):
  - Likely candidates for FinOps analytics (not exhaustively validated in this note):
    - `QUERY_HISTORY` (query-level attribution via `QUERY_TAG`, warehouse, user, etc.)
    - Warehouse metering history views (e.g., `WAREHOUSE_METERING_HISTORY` / similar) for credit consumption by warehouse over time.
  - Reference page (full catalog): `ACCOUNT_USAGE` documentation.
- `SNOWFLAKE.ORGANIZATION_USAGE` (org-scoped, ~24h latency):
  - `ORGANIZATION_USAGE.ACCOUNTS` and other org-level views for multi-account rollups.
  - Some views are premium/organization-account only (must detect availability and degrade gracefully).
- Tagging primitives:
  - **Object tags** (for warehouses, databases, schemas, users, roles, etc.) — used for “who owns this resource” / “which cost center”.
  - **Query tags** (`QUERY_TAG` parameter) — used for request-scoped attribution when a shared service runs queries for multiple cost centers.

## MVP features unlocked (PR-sized)
1) **Attribution “coverage” report** (daily): % of spend attributed via tags/query_tag, with drill-down to top untagged warehouses/users/queries.
2) **Opinionated attribution model**: map every credit to one of: {warehouse tag → query_tag → user tag → unallocated}, with explicit precedence and explainability.
3) **Control recommendations**: detect where resource monitors are missing / misconfigured for high-cost warehouses and propose “safe defaults” (notify first, suspend later).

## Heuristics / detection logic (v1)
- **Attribution precedence (suggested):**
  1) If query has `QUERY_TAG` matching an allowed cost-unit format → attribute query cost there.
  2) Else if warehouse has `COST_CENTER` tag → attribute to warehouse cost center.
  3) Else if user has `COST_CENTER` tag → attribute to user cost center.
  4) Else `UNALLOCATED`.
- **Coverage metric:** `attributed_credits / total_credits` per day/account/warehouse.
- **Control gap:** warehouses with high credits/day and no resource monitor assignment (or monitor thresholds too high / no notify action) → flag.

## Concrete artifact — SQL draft (daily cost attribution skeleton)
> Goal: produce a daily table `FINOPS_DAILY_ATTRIBUTION` keyed by `date, warehouse_name, cost_unit`.
>
> Notes:
> - Exact column names can vary by view version/edition; treat as a starter and validate against the account’s `ACCOUNT_USAGE` schema.
> - A more accurate model allocates warehouse metering credits to queries by runtime share; this draft starts from query-level and rolls up.

```sql
-- Inputs:
-- 1) SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY (query-level metadata; includes QUERY_TAG)
-- 2) Tag lookups for warehouses/users (implementation depends on how tags are exposed; may require INFORMATION_SCHEMA table functions)
--
-- Output:
--   date, warehouse_name, cost_unit, query_count, total_execution_seconds (proxy), notes

create or replace table APP_FINOPS.FINOPS_DAILY_ATTRIBUTION as
with q as (
  select
    date_trunc('day', start_time) as usage_date,
    warehouse_name,
    user_name,
    nullif(query_tag, '') as query_tag,
    datediff('second', start_time, end_time) as exec_seconds
  from SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  where start_time >= dateadd('day', -30, current_timestamp())
    and warehouse_name is not null
),
-- Placeholder: replace with real tag resolution for warehouse/user.
-- Many accounts will implement a curated dimension table populated via scheduled jobs.
warehouse_tags as (
  select warehouse_name, cost_center as warehouse_cost_center
  from APP_FINOPS.DIM_WAREHOUSE_TAGS
),
user_tags as (
  select user_name, cost_center as user_cost_center
  from APP_FINOPS.DIM_USER_TAGS
),
classified as (
  select
    q.usage_date,
    q.warehouse_name,
    coalesce(
      q.query_tag,
      wt.warehouse_cost_center,
      ut.user_cost_center,
      'UNALLOCATED'
    ) as cost_unit,
    q.exec_seconds
  from q
  left join warehouse_tags wt using (warehouse_name)
  left join user_tags ut using (user_name)
)
select
  usage_date::date as usage_date,
  warehouse_name,
  cost_unit,
  count(*) as query_count,
  sum(exec_seconds) as total_execution_seconds
from classified
group by 1,2,3;
```

## Security/RBAC notes
- The native app will typically need **read access** to `SNOWFLAKE.ACCOUNT_USAGE` and/or `SNOWFLAKE.ORGANIZATION_USAGE` to compute analytics; availability depends on edition/role grants.
- Access to **tag metadata** may require additional privileges; design the app to support a “bring-your-own-dimension” model where customers populate `DIM_*_TAGS` in an app-owned schema if direct tag reads are constrained.
- Organization-wide views can be premium/limited; the app must detect what’s available and degrade to account-scoped metrics.

## Risks / assumptions
- Assumption: `QUERY_HISTORY` and a warehouse metering view are accessible and sufficiently complete for attribution; in practice, latency and retention vary and some views require higher edition.
- Attribution accuracy: mapping credits to queries is non-trivial (warehouse credits include idle time; queries overlap; cloud services credits). A v1 can focus on **query activity attribution** (usage proxies) and separately show metered credits by warehouse.
- Tag extraction: exact Snowflake mechanisms to query object tags in bulk may vary; confirm best-practice approach for reading tags at scale and with least privilege.

## Links / references
- Snowflake Well-Architected — Cost Optimization & FinOps: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- Snowflake docs — Account Usage: https://docs.snowflake.com/en/sql-reference/account-usage
- Snowflake docs — Organization Usage: https://docs.snowflake.com/en/sql-reference/organization-usage
- Snowflake docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
- Snowflake docs — Working with resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
