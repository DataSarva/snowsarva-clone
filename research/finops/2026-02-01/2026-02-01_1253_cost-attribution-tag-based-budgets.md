# FinOps Research Note — Cost attribution via tags + per-query costs; foundation for tag-based budgets

- **When (UTC):** 2026-02-01 12:53
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App can deliver **chargeback/showback** by cost center, plus **budgeting/alerts**, using Snowflake’s recommended primitives: object tags + query tags, and cost/attribution views. This is a clean “native” path because it’s largely SQL + RBAC + optional UI.

## Accurate takeaways
- Snowflake’s recommended cost attribution approach is:
  - use **object tags** to associate resources/users with a cost center, and
  - use **query tags** when a shared application executes queries on behalf of multiple cost centers.  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- For **within-account** attribution by tag, Snowflake explicitly points to joining:
  - `ACCOUNT_USAGE.TAG_REFERENCES` (objects + tag values)
  - `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (warehouse credits)
  - `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute cost)  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides compute cost per query for warehouse-run queries in the account for up to **365 days** (per the view description).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
- Snowflake has introduced **tag-based budgets** that directly leverage **object tags** so budgets align to business dimensions without manual mapping of resources to budgets.  
  Source: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Snowflake objects & data sources (verify in target account)
- `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`
  - Use: resolve `(tag_name, tag_value)` for objects (warehouses/users/etc.).
  - Notes: referenced by Snowflake’s cost attribution docs for SQL-based breakdowns.
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`
  - Use: warehouse credit consumption over time (hourly slices).
- `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY`
  - Use: per-query compute cost attribution (warehouse credit usage allocated to queries).
  - Limitation: **account-level** scope; Snowflake notes there is **no organization-wide equivalent** of this view (important for multi-account org rollups).
- Org-wide angle (needs verification in a real org account): Snowflake indicates some tag reference data exists in `ORGANIZATION_USAGE`, but also notes availability constraints (e.g., TAG_REFERENCES only available in org account; QUERY_ATTRIBUTION_HISTORY not available org-wide).  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing

## MVP features unlocked (PR-sized)
1) **Cost by cost_center (warehouse-level)**: daily credits and $ by `cost_center` object tag (on warehouses), with “unattributed” bucket for untagged warehouses.
2) **Cost by cost_center (user/query-level)**: per-query compute cost rollup joined to user tags (when warehouses are shared across departments).
3) **Tag coverage + drift**: report of top cost drivers that are missing required tags, plus “new warehouses/users created without tags” (compliance nudge).

## Heuristics / detection logic (v1)
- **Primary attribution dimension**: `tag_name = 'COST_CENTER'` (or configurable).
- **Attribution order** (pragmatic):
  1) If warehouse has COST_CENTER tag → attribute all warehouse metering to that tag.
  2) Else if user has COST_CENTER tag → attribute per-query compute (from `QUERY_ATTRIBUTION_HISTORY`) to the user’s tag.
  3) Else → `COST_CENTER = 'UNATTRIBUTED'`.
- **Quality signals**:
  - % of total credits that land in `UNATTRIBUTED` (should trend down).
  - Top warehouses by credits missing tag.
  - Top users by per-query cost missing tag.

## Security/RBAC notes
- These ACCOUNT_USAGE views typically require `MONITOR USAGE` (and/or imported privileges depending on packaging context). Validate required grants for a packaged Native App role.
- Tag reads can be sensitive (org structure); consider restricting which tag names the app can query (allowlist) and/or storing only aggregated outputs.

## Risks / assumptions
- **Pricing**: Converting credits → dollars is non-trivial (rate cards, editions, negotiated contracts). This note assumes credits-first reporting; currency conversion may require ORG/BILLING views or manual inputs.
- **Org rollups**: If we need multi-account org-wide query-level attribution, the lack of an org-wide `QUERY_ATTRIBUTION_HISTORY` equivalent implies either:
  - deploy per-account and aggregate externally, or
  - accept warehouse-level org rollups only.
- **Tag policy variance**: real accounts may use multiple tag taxonomies; app must be configurable (tag name, case sensitivity, optional values).

## Concrete artifact — SQL draft (v1)
Below is a *starting point* view to attribute **warehouse metering credits** to a warehouse COST_CENTER tag.

```sql
-- Purpose: Daily warehouse credits attributed to a COST_CENTER object tag on WAREHOUSE.
-- Sources: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, TAG_REFERENCES
-- Caveat: verify column names for TAG_REFERENCES object identification in your account.

create or replace view FINOPS.COST_ATTRIBUTION.DAILY_WAREHOUSE_CREDITS_BY_COST_CENTER as
with tag_wh as (
  select
    tr.object_id,
    tr.tag_name,
    tr.tag_value
  from snowflake.account_usage.tag_references tr
  where tr.domain = 'WAREHOUSE'
    and upper(tr.tag_name) = 'COST_CENTER'
), wh_metering as (
  select
    date_trunc('day', start_time) as day,
    warehouse_id,
    sum(credits_used) as credits_used
  from snowflake.account_usage.warehouse_metering_history
  where start_time >= dateadd('day', -90, current_timestamp())
  group by 1, 2
)
select
  m.day,
  coalesce(t.tag_value, 'UNATTRIBUTED') as cost_center,
  sum(m.credits_used) as credits_used
from wh_metering m
left join tag_wh t
  on t.object_id = m.warehouse_id
group by 1, 2
order by 1 desc, 3 desc;
```

Next step artifact (not written here): a companion model using `QUERY_ATTRIBUTION_HISTORY` to allocate shared-warehouse spend to user COST_CENTER tags.

## Links / references
- Snowflake docs — Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
- Snowflake docs — QUERY_ATTRIBUTION_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
- Snowflake engineering blog — Tag-based budgets: https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/
