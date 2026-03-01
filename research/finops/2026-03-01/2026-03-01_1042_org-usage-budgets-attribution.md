# Research: FinOps - 2026-03-01

**Time:** 10:42 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake exposes organization-wide historical usage data across all accounts via the shared `SNOWFLAKE.ORGANIZATION_USAGE` schema (accessible from the organization account and also from an ORGADMIN-enabled account, with different access mechanics/roles).  
   Source: Snowflake docs, “Organization Usage”.
2. `SNOWFLAKE.ORGANIZATION_USAGE` includes both usage and billing-oriented views (e.g., `METERING_DAILY_HISTORY`, `USAGE_IN_CURRENCY_DAILY`, `REMAINING_BALANCE_DAILY`), and many views have non-trivial latency (commonly 24h; some 2h; some 72h).  
   Source: Snowflake docs, “Organization Usage”.
3. Budgets in Snowflake define a monthly spending limit (in credits) for either an account budget (all credit usage) or custom budgets (a group of supported objects), and send notifications when spend is projected to exceed the limit. Notifications can go to email, cloud queues, or webhooks.  
   Source: Snowflake docs, “Monitor credit usage with budgets”.
4. Budgets have a default “refresh interval” up to ~6.5 hours; there is a “low latency budget” option with 1-hour refresh, and Snowflake documents that 1-hour refresh increases the compute cost of the budget by a factor of 12.  
   Source: Snowflake docs, “Monitor credit usage with budgets”.
5. Snowflake’s recommended approach for cost attribution uses **object tags** (to associate resources/users to cost centers) and **query tags** (to attribute queries when an app runs queries on behalf of multiple cost centers).  
   Source: Snowflake docs, “Attributing cost”.
6. Cost attribution data sources differ by scope:
   - Within a single account, you can use `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, and `QUERY_ATTRIBUTION_HISTORY` for attribution.  
   - Org-wide, `SNOWFLAKE.ORGANIZATION_USAGE` can be used for resources exclusively owned by a department, but Snowflake documents that `QUERY_ATTRIBUTION_HISTORY` does **not** have an organization-wide equivalent (it is only in `ACCOUNT_USAGE`).  
   Source: Snowflake docs, “Attributing cost”.
7. `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` is hourly and includes `CREDITS_USED_COMPUTE` and `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (query-attributed credits exclude idle time). Snowflake provides example SQL to calculate “idle cost” as `SUM(credits_used_compute) - SUM(credits_attributed_compute_queries)` over a period.  
   Source: Snowflake docs, “WAREHOUSE_METERING_HISTORY view”.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | Historical | ORG_USAGE | Daily metering; org-wide; view list indicates ~2h latency; 1y retention (per org usage catalog table). |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | Historical | ORG_USAGE | Billing-oriented; org-wide; doc notes billing views may have end-of-month adjustments; also access limitations for reseller contracts. |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | Historical | ORG_USAGE | Hourly warehouse credits; org-wide; 1y retention (per org usage catalog table). |
| `SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY` | Historical | ORG_USAGE | Average daily storage usage (bytes) across org; ~2h latency; 1y retention (seen in search excerpt). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | Historical | ACCOUNT_USAGE | Hourly warehouse credits; latency up to 3h (cloud services column up to 6h); includes `CREDITS_ATTRIBUTED_COMPUTE_QUERIES` (idle excluded). |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | Historical | ACCOUNT_USAGE | Per-query attributed compute credits; latency up to ~8h; **no org-wide equivalent**. |
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | Object | ACCOUNT_USAGE | Join point for tags to objects/users (domain-based). |
| `SNOWFLAKE.ORGANIZATION_USAGE.TAG_REFERENCES` | Object | ORG_USAGE | Doc notes availability in org account; used for org-wide attribution of resources exclusively owned by a department. |
| Budgets (`SNOWFLAKE.CORE.BUDGET` class) | Object | Snowflake Core | Budgets are configured objects; monitoring monthly; refresh tier tradeoff (default vs low-latency). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Org-wide “Cost Facts” table/view (daily + hourly)**: A canonical model that unifies `ORG_USAGE` metering + storage + currency views into a single “fact_cost_daily” dataset per account/region/service_type, with documented latency/retention.
2. **Idle-cost surfacing by warehouse + attribution fallback**: For any warehouse, compute idle cost using `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` and expose “idle_ratio” (idle / total) to flag misconfigured auto-suspend or overprovisioning.
3. **Coverage analyzer for chargeback readiness**: A report showing what % of spend is attributable by tags (warehouse tags, user tags, query tags), and where org-wide attribution is blocked due to per-query data being account-local.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Artifact: SQL draft for a minimal “Cost Facts” layer (org + account)

Goal: produce a **single schema** that the Native App can query, while being explicit about what is org-wide vs account-local.

```sql
-- Schema suggestion: FINOPS.COST
-- This draft intentionally separates ORG-wide from ACCOUNT-local facts.

-- 1) ORG-wide daily costs in currency (best for executive reporting)
CREATE OR REPLACE VIEW finops.cost.fact_org_usage_currency_daily AS
SELECT
  usage_date,
  account_locator,
  account_name,
  region,
  service_type,
  usage,
  usage_in_currency,
  currency,
  balance_source,
  contract_number
FROM snowflake.organization_usage.usage_in_currency_daily;

-- 2) ORG-wide hourly warehouse credits (capacity/ops view)
CREATE OR REPLACE VIEW finops.cost.fact_org_warehouse_metering_hourly AS
SELECT
  start_time,
  end_time,
  account_locator,
  account_name,
  region,
  warehouse_id,
  warehouse_name,
  credits_used,
  credits_used_compute,
  credits_used_cloud_services
FROM snowflake.organization_usage.warehouse_metering_history;

-- 3) ACCOUNT-local hourly warehouse credits + idle cost (for deep-dive + action)
CREATE OR REPLACE VIEW finops.cost.fact_account_warehouse_idle_hourly AS
SELECT
  start_time,
  warehouse_id,
  warehouse_name,
  credits_used_compute,
  credits_attributed_compute_queries,
  (credits_used_compute - credits_attributed_compute_queries) AS credits_idle_compute,
  IFF(credits_used_compute = 0, NULL,
      (credits_used_compute - credits_attributed_compute_queries) / credits_used_compute) AS idle_ratio
FROM snowflake.account_usage.warehouse_metering_history
WHERE warehouse_id > 0; -- avoid pseudo-warehouses

-- 4) ACCOUNT-local per-query costs (cannot be org-wide per Snowflake docs)
CREATE OR REPLACE VIEW finops.cost.fact_account_query_attribution AS
SELECT
  query_id,
  start_time,
  end_time,
  warehouse_id,
  warehouse_name,
  user_name,
  query_tag,
  credits_attributed_compute,
  credits_used_query_acceleration
FROM snowflake.account_usage.query_attribution_history;
```

Why this matters for the Native App: it lets the UI answer two common workflows cleanly:
- “What did we spend yesterday across all accounts?” → org-wide daily currency view.
- “Which warehouse is wasting credits?” → account-local idle ratio.
- “Which queries / tags / users drive cost?” → account-local `QUERY_ATTRIBUTION_HISTORY`.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Organization-wide per-query cost attribution is not available (no org-wide `QUERY_ATTRIBUTION_HISTORY`). | Native App must either (a) deploy/execute account-local collectors, or (b) accept that deep per-query chargeback is scoped per account. | Confirmed in Snowflake docs “Attributing cost” notes `QUERY_ATTRIBUTION_HISTORY` is only in `ACCOUNT_USAGE`. |
| Budgets low-latency (1-hour refresh) can be significantly more expensive to run (12x). | If app recommends enabling low-latency budgets broadly, it could itself increase spend and create customer dissatisfaction. | Snowflake docs “Monitor credit usage with budgets” states 12x cost factor. |
| ORG_USAGE view latencies (2h/24h/72h) limit “near-real-time” monitoring. | Any alerting/nearline dashboards must account for ingestion delay and set expectations. | ORG_USAGE docs list latencies; budget refresh interval docs also suggest several hours default. |
| Some organization billing views may not show final end-of-month adjusted amounts, and reseller contracts may block access. | Currency-based reporting may differ from invoices; app needs disclaimers and reconciliation guidance. | Noted in ORG_USAGE docs table footnote for billing views. |

## Links & Citations

1. https://docs.snowflake.com/en/sql-reference/organization-usage
2. https://docs.snowflake.com/en/user-guide/budgets
3. https://docs.snowflake.com/en/user-guide/cost-attributing
4. https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history

## Next Steps / Follow-ups

- Decide which “cost facts” the Native App should treat as canonical for (a) exec reporting (currency daily) vs (b) engineering action (hourly metering + idle ratio) vs (c) chargeback/showback (tags + query attribution).
- Extend artifact with a **tag-coverage** view (e.g., % of warehouse credits from tagged warehouses; % of query credits with non-empty `QUERY_TAG`).
- If we need org-wide per-query attribution, research patterns for deploying an app-side collector that runs in each account and writes into a central org account (governance + data sharing implications).
