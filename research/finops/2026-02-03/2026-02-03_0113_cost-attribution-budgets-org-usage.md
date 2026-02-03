# FinOps Research Note — Cost attribution primitives (tags + query attribution) + proactive controls (budgets) across accounts

- **When (UTC):** 2026-02-03 01:13
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs *portable, least-privilege* primitives for (a) attributing spend to cost centers and (b) proactive controls/alerts. Snowflake’s recommended model is tags + attribution views, but there are important scope limits (account vs org) that should shape the app’s data model and UI.

## Accurate takeaways
- Snowflake’s recommended cost attribution approach is:
  - **Object tags** to associate resources/users with departments/projects.
  - **Query tags** to associate individual queries when the same app runs queries on behalf of multiple departments/users.  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- Cost attribution scenarios called out explicitly include:
  - Dedicated resources per cost center (e.g., warehouses tagged to a department)
  - Shared warehouses across departments (attribute via tagged users + per-query attribution)
  - Shared applications/workflows (attribute via query_tag)  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- **QUERY_ATTRIBUTION_HISTORY is account-scoped only** (Snowflake explicitly notes there is *no* organization-wide equivalent). This is a key product constraint: org-level rollups can’t do per-query attribution across accounts.  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- Snowflake provides org-wide historical usage data in **SNOWFLAKE.ORGANIZATION_USAGE** (from an organization account), with stated latencies (commonly ~24h for many views).  
  Source: https://docs.snowflake.com/en/sql-reference/organization-usage
- Snowflake “budgets” provide a **monthly spending limit** on compute costs for an account or **custom group of objects**, and can notify via email, cloud queues (SNS/Event Grid/PubSub), or webhooks to 3rd-party systems.  
  Source: https://docs.snowflake.com/en/user-guide/budgets
- ACCOUNT_USAGE (SNOWFLAKE.ACCOUNT_USAGE) provides account-level historical usage/object metadata, with differences vs Information Schema (e.g., longer retention, data latency, includes dropped objects).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage

## Snowflake objects & data sources (verify in target account)
- **Tagging / attribution**
  - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (tagged objects; join surface)
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (warehouse credit usage)
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query attributed compute credits; excludes idle)
  - `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` (org-wide warehouse metering history)
  - `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` (note: docs indicate TAG_REFERENCES in ORG_USAGE is only available in the **organization account**)
  - Session parameter / column: `QUERY_TAG` (set via `ALTER SESSION SET QUERY_TAG = '...'`)
- **Controls / alerts**
  - Budgets objects + notification integrations (email/webhook/cloud queue). Data-plane objects/views to query were not identified in today’s read; treat as **unknown** until we locate the reference views/events.

## MVP features unlocked (PR-sized)
1) **Org-level warehouse spend by tag (showback)**: If the user runs the app from the organization account, compute monthly credits by `tag_name/tag_value` across all accounts using ORG_USAGE metering + tag references.
2) **Account-level “shared warehouse” attribution pack**: For each connected account, compute department spend (tagged users) using `QUERY_ATTRIBUTION_HISTORY` joined to `TAG_REFERENCES` (USER domain).
3) **Budget wiring guide + webhook sink**: Provide a “copy/paste” webhook endpoint + recommended budget configuration for alerts into the app (the app receives alerts and correlates to cost centers/objects).

## Heuristics / detection logic (v1)
- **Coverage checks**
  - % of warehouses tagged with cost-center tag (WAREHOUSE domain)
  - % of active users tagged with cost-center tag (USER domain)
  - % of queries with non-empty `QUERY_TAG` (or follow a key=value convention)
- **Attribution mode selector (UI)**
  - If org account available: enable org-level warehouse spend by tag.
  - Always enable account-level per-query attribution (with clear caveat that it excludes idle and is account-scoped).

## Security/RBAC notes
- The app will need read access to:
  - `SNOWFLAKE.ACCOUNT_USAGE` views for account-scoped analysis.
  - `SNOWFLAKE.ORGANIZATION_USAGE` for org-scoped rollups (only possible from org account; some views are premium).
- Tag-based attribution requires the ability to *read* tag references; tagging automation requires elevated privileges (likely outside app scope; better to provide recommendations + optional helper procedures if customer opts in).

## Risks / assumptions
- **Latency**: ORG_USAGE docs list latencies (commonly 24h). If customers expect near-real-time dashboards, we’ll need explicit UX + caching strategies.
- **Scope mismatch**: Per-query attribution cannot be rolled up org-wide (explicit doc constraint). Our product should avoid implying cross-account per-query chargeback.
- **Budgets telemetry**: We have budget creation/configuration docs, but we have not yet verified the exact queryable history views/events for budgets/alerts; MVP may rely on webhook ingestion as the source of truth.

## Concrete artifact — SQL drafts

### A) Organization-wide monthly warehouse credits by COST_CENTER tag (WAREHOUSE domain)
> Uses the pattern shown in Snowflake’s “Attributing cost” guide; adapted to ORG_USAGE. Validate column names in your account.

```sql
-- Org account context
-- Goal: monthly warehouse credits by tag_value across all accounts
-- (Assumes tag lives in COST_MANAGEMENT.TAGS and tag_name = COST_CENTER)

WITH month_window AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS month_start,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS month_end
)
SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits
FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY wmh
LEFT JOIN SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES tr
  ON wmh.warehouse_id = tr.object_id
  AND tr.domain = 'WAREHOUSE'
  -- If you standardize tag DB/SCHEMA, keep these predicates; otherwise remove.
  AND tr.tag_database = 'COST_MANAGEMENT'
  AND tr.tag_schema = 'TAGS'
-- optionally: AND tr.tag_name = 'COST_CENTER'
JOIN month_window mw
  ON wmh.start_time >= mw.month_start
 AND wmh.start_time <  mw.month_end
GROUP BY 1, 2
ORDER BY total_credits DESC;
```

### B) Account-level monthly attributed credits by department (USER domain tags)
> Mirrors Snowflake’s documented pattern: join USER tag references with QUERY_ATTRIBUTION_HISTORY.

```sql
WITH joined AS (
  SELECT
    tr.tag_name,
    tr.tag_value,
    qah.credits_attributed_compute,
    qah.start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
    ON tr.domain = 'USER'
   AND tr.object_name = qah.user_name
)
SELECT
  tag_name,
  tag_value,
  SUM(credits_attributed_compute) AS total_credits
FROM joined
WHERE start_time >= DATEADD(MONTH, -1, CURRENT_DATE())
  AND start_time < CURRENT_DATE()
GROUP BY 1, 2
ORDER BY 1, 2;
```

### C) “Query-tag coverage” hygiene metric
```sql
SELECT
  DATE_TRUNC('DAY', start_time) AS day,
  COUNT(*) AS total_queries,
  SUM(IFF(COALESCE(NULLIF(query_tag, ''), '') = '', 0, 1)) AS tagged_queries,
  tagged_queries / NULLIF(total_queries, 0) AS pct_tagged
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD(DAY, -30, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;
```

## Links / references
- Attributing cost (tags + query attribution, plus org vs account scope notes): https://docs.snowflake.com/en/user-guide/cost-attributing
- Account Usage overview (ACCOUNT_USAGE semantics/latency/retention framing): https://docs.snowflake.com/en/sql-reference/account-usage
- Organization Usage overview (ORG_USAGE availability + latency): https://docs.snowflake.com/en/sql-reference/organization-usage
- Budgets overview (monthly spending limit + notifications incl. webhook): https://docs.snowflake.com/en/user-guide/budgets
