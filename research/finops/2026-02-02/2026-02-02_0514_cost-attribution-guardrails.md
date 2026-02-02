# FinOps Research Note — Cost attribution + guardrails primitives (tags, query tags, monitors) for the Native App

- **When (UTC):** 2026-02-02 05:14
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A FinOps Native App needs *repeatable primitives* for (1) attributing compute/storage to owners (showback/chargeback) and (2) enforcing guardrails. Snowflake’s recommended building blocks are object tags + query tags (for attribution) and resource monitors/budgets (for controls), with ACCOUNT_USAGE/ORG_USAGE views as the data plane.

## Accurate takeaways
- Snowflake explicitly recommends combining **object tags** (warehouses, databases, tables, users) with usage views (e.g., **WAREHOUSE_METERING_HISTORY**, **TABLE_STORAGE_METRICS**) and **TAG_REFERENCES** to enable *granular cost attribution* in dashboards/showback models. Source: Snowflake Cost Optimization (Well-Architected cost/FinOps guide). https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- **Query tags** can be set at the session level (e.g., `ALTER SESSION SET QUERY_TAG = '...'`) to attribute costs/workloads even when multiple teams share a warehouse; query tags are exposed via **QUERY_HISTORY** in `SNOWFLAKE.ACCOUNT_USAGE`. Source: Snowflake Cost Optimization (Well-Architected cost/FinOps guide). https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- Snowflake provides a first-class concept for **cost attribution** (“apportion the cost of using Snowflake to logical units”) in its user guide; for a Native App this implies a v1 product can focus on (a) ingestion of usage data, (b) mapping usage → owner dimensions (tags/query tags), and (c) producing explainable rollups. Source: Snowflake “Attributing cost”. https://docs.snowflake.com/en/user-guide/cost-attributing
- **Multi-cluster warehouses** are a scaling mechanism (Enterprise Edition feature) that can change compute consumption patterns; a FinOps product should surface cluster scaling settings and recommend bounded configs (min/max clusters) based on queueing/concurrency vs cost tradeoffs. Source: Snowflake “Multi-cluster warehouses”. https://docs.snowflake.com/en/user-guide/warehouses-multicluster
- `SNOWFLAKE.ACCOUNT_USAGE` is the canonical schema for many account-level administrative/usage views; a FinOps app should treat it as “authoritative but delayed” telemetry (docs page is a central index for the schema). Source: Snowflake ACCOUNT_USAGE reference. https://docs.snowflake.com/en/sql-reference/account-usage
- **Resource monitors** are the canonical guardrail for tracking and controlling credit consumption (including setting thresholds and automated actions). Source: Snowflake “Resource monitors”. https://docs.snowflake.com/en/user-guide/resource-monitors

## Snowflake objects & data sources (verify in target account)
- Telemetry / usage:
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (compute credits by warehouse over time) — referenced as a primary building block for attribution. (Referenced in the FinOps guide; details/columns should be verified per account.)
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (query-level history including `QUERY_TAG`) — used for workload attribution on shared warehouses.
  - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (maps object tags to objects) — enables joining tags to usage facts.
  - `SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS` (storage metrics) — referenced for storage attribution.
  - `SNOWFLAKE.ACCOUNT_USAGE` (schema index + many additional views) — treat as the main starting point for admins.
- Controls:
  - Resource monitors (DDL-managed objects; surfaced via SHOW/DESC/ACCOUNT_USAGE views depending on feature exposure) — verify what monitoring metadata is queryable in the account + which privileges are required.
- Warehouse configuration:
  - Multi-cluster warehouse settings (min/max clusters, scaling policy, etc.) — verify where to read config (e.g., `SHOW WAREHOUSES` + `RESULT_SCAN`, or account usage metadata views if available).

## MVP features unlocked (PR-sized)
1) **Attribution joiner v1:** Provide a canonical SQL view that joins `WAREHOUSE_METERING_HISTORY` → `TAG_REFERENCES` (warehouse tags) to produce “credits by cost_center/env/team” time series.
2) **Shared warehouse workload split v1:** Use `QUERY_HISTORY.QUERY_TAG` to allocate a shared warehouse’s compute to query tags (with a clearly labeled heuristic), producing “estimated credits by query_tag”.
3) **Guardrail inventory v1:** Surface a resource monitor inventory (name, credit quota, triggers/actions) + alerts when thresholds are near (based on current period usage).

## Heuristics / detection logic (v1)
- **Tag-based showback:** Aggregate credits by warehouse and day/hour; join to warehouse tag(s). If multiple tags exist, prefer a policy (e.g., `cost_center` wins; otherwise `team`).
- **Query-tag allocation for shared warehouses (heuristic):**
  - For each warehouse and time bucket, apportion metered credits across query tags by relative query execution time in that bucket (or by bytes scanned / time), then validate with sampling.
  - Mark as *estimated*; expose residual “unattributed” usage.
- **Multi-cluster cost risk flag:** If a warehouse has max clusters > 1 and sustained high concurrency, prompt review of scaling policy; if max clusters > 1 but concurrency low, flag potential overprovisioning.

## Concrete artifact: SQL draft (attribution view)
> Goal: a minimally invasive “facts + dims” layer the Native App can materialize into its own schema.

```sql
-- 1) Pull warehouse metering facts.
WITH wh_credits AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    SUM(credits_used_compute) AS credits_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),

-- 2) Pull warehouse tag references (dim).
-- NOTE: confirm the exact columns for TAG_REFERENCES in the target account.
wh_tags AS (
  SELECT
    object_name            AS warehouse_name,
    tag_name,
    tag_value
  FROM snowflake.account_usage.tag_references
  WHERE domain = 'WAREHOUSE'
),

-- 3) Pivot a few key tags (policy: pick a fixed set).
wh_tag_dim AS (
  SELECT
    warehouse_name,
    MAX(IFF(tag_name ILIKE '%COST_CENTER%', tag_value, NULL)) AS cost_center,
    MAX(IFF(tag_name ILIKE '%TEAM%',        tag_value, NULL)) AS team,
    MAX(IFF(tag_name ILIKE '%ENV%',         tag_value, NULL)) AS env
  FROM wh_tags
  GROUP BY 1
)

SELECT
  f.hour_ts,
  f.warehouse_name,
  d.cost_center,
  d.team,
  d.env,
  f.credits_compute
FROM wh_credits f
LEFT JOIN wh_tag_dim d
  ON f.warehouse_name = d.warehouse_name;
```

## Security/RBAC notes
- A Native App should avoid requiring overly broad privileges; but reading `SNOWFLAKE.ACCOUNT_USAGE` commonly requires elevated monitor/admin capabilities. The app should:
  - Clearly document required privileges (e.g., read access to `SNOWFLAKE.ACCOUNT_USAGE` views used).
  - Support partial operation if certain views aren’t accessible (degraded mode).
- Query-tag and tag-reference data can reveal organizational metadata (team names, project names). Treat it as sensitive and ensure UI respects RBAC.

## Risks / assumptions
- Assumption: `TAG_REFERENCES` contains a stable mapping from warehouse name → tag value suitable for joining with metering history; exact join keys and column names must be verified in practice.
- ACCOUNT_USAGE latency/retention constraints may affect “near-real-time” experiences; a FinOps app may need to supplement with eventing/logging or accept delayed telemetry.
- Query-tag allocation from `QUERY_HISTORY` to warehouse credits is not exact (Snowflake does not directly bill per query in credits); any split is heuristic and must be labeled.
- Multi-cluster recommendations require careful context (SLA/concurrency vs cost); avoid “always reduce clusters” style rules.

## Links / references
- Snowflake Well-Architected: Cost Optimization & FinOps: https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/
- Snowflake docs: Attributing cost: https://docs.snowflake.com/en/user-guide/cost-attributing
- Snowflake docs: Multi-cluster warehouses: https://docs.snowflake.com/en/user-guide/warehouses-multicluster
- Snowflake docs: ACCOUNT_USAGE schema reference: https://docs.snowflake.com/en/sql-reference/account-usage
- Snowflake docs: Resource monitors: https://docs.snowflake.com/en/user-guide/resource-monitors
