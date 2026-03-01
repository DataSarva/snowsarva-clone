# Research: FinOps - 2026-03-01

**Time:** 02:16 UTC  
**Topic:** Snowflake FinOps Cost Telemetry Sources + How to Monetize a Native App Without Breaking Supportability  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` provides **hourly** credit usage entries for the last **365 days**, broken down by `SERVICE_TYPE` (warehouses, serverless, cloud services, etc.) and sometimes by an `ENTITY_ID`/`ENTITY_TYPE` pair. The view can be delayed up to **3 hours** (and some columns longer).  
   Source: Snowflake docs for `METERING_HISTORY`. [https://docs.snowflake.com/en/sql-reference/account-usage/metering_history](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history)

2. `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` provides **daily** credits for the last **365 days** and includes a `CREDITS_ADJUSTMENT_CLOUD_SERVICES` field that enables computing **billed** cloud services credits (because cloud services credits consumed are not always billed).  
   Source: Snowflake docs for `METERING_DAILY_HISTORY`. [https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history](https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history)

3. Snowflake’s Marketplace “usage-based” pricing for listings that share an **application** can include **Custom Event Billing** (“billable events”), plus optional **per-query** charges and/or a **monthly fee**. Providers can only charge for the billable event classes they explicitly configure in the listing UI, even if the app emits other classes.  
   Source: Paid listings pricing models. [https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model](https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model)

4. Snowflake Custom Event Billing for a Native App is implemented by calling `SYSTEM$CREATE_BILLING_EVENT` (or batching with `SYSTEM$CREATE_BILLING_EVENTS`) from within stored procedures inside the app; Snowflake explicitly states that using telemetry/event-table output as the basis for billing is **not supported**.  
   Source: Add billable events to an application package. [https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing](https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing)

5. For Native Apps that use Snowpark Container Services (SPCS), **infrastructure costs** (warehouses, compute pools, storage, data transfer) are the **consumer’s** responsibility; providers can additionally monetize via Marketplace pricing models. Compute pool costs are not incurred when compute pools are **suspended**.  
   Source: Costs associated with apps with containers. [https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance](https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance)

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|---|---|---|---|
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY` | View | `ACCOUNT_USAGE` | Hourly credits by `SERVICE_TYPE`; includes `CREDITS_USED_COMPUTE` vs `CREDITS_USED_CLOUD_SERVICES`. Latency can be up to 3h+ depending on column/service. [docs](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Daily credits and the cloud-services adjustment (`CREDITS_ADJUSTMENT_CLOUD_SERVICES`) needed for billed cloud services. [docs](https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history) |
| `SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY` | View | `ORG_USAGE` | Daily credits across accounts, includes account identifiers. Useful for multi-account FinOps rollups (org-level). [docs](https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history) |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query-level metadata + `credits_used_cloud_services` (consumed), but billed cloud-services requires `METERING_DAILY_HISTORY`. [docs](https://docs.snowflake.com/en/sql-reference/account-usage/query_history) |
| `SNOWFLAKE.DATA_SHARING_USAGE.MARKETPLACE_PAID_USAGE_DAILY` | View | `DATA_SHARING_USAGE` | Used (in consumer accounts) to validate Marketplace charges (including monetizable billing events) after latency. Mentioned in Custom Event Billing docs. [docs](https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing) |
| `SYSTEM$CREATE_BILLING_EVENT(S)` | System function | N/A | Only callable meaningfully from an installed Native App in a consumer account; used to emit billable events for Marketplace. [docs](https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing) |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata/usage
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

---

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Billed vs Consumed” compute rollup widget**: daily chart that shows `CREDITS_USED` vs `CREDITS_BILLED` for cloud services using `METERING_DAILY_HISTORY` (explain the adjustment), with drill-down to `SERVICE_TYPE`.

2. **Hourly service heatmap**: `METERING_HISTORY` grouped by `SERVICE_TYPE` (WAREHOUSE_METERING, PIPE, SEARCH_OPTIMIZATION, SNOWPARK_CONTAINER_SERVICES, etc.) to spot unexpected serverless spend spikes.

3. **Provider monetization guardrails lint**: static checks that validate our app’s emitted billing event classes + billing_quantity are mirrored 1:1 in the listing config, since Snowflake only pays for configured classes. (This can be a local CI rule + a “pricing manifest” file in-repo.)

---

## Concrete Artifacts

### Artifact: Canonical “service-day billed credits” fact view (SQL draft)

Goal: standardize one internal dataset the FinOps Native App can build on:
- **daily** grains
- supports **service_type** breakdown
- reports **billed** credits (especially cloud services)
- makes UTC alignment explicit

```sql
-- FACT: daily credits billed/consumed by service type
-- Source-of-truth for billed cloud services is ACCOUNT_USAGE.METERING_DAILY_HISTORY.
-- Docs:
--  - https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history
--  - https://docs.snowflake.com/en/sql-reference/account-usage/metering_history

CREATE OR REPLACE VIEW FINOPS.FACT_SERVICE_CREDITS_DAILY AS
WITH src AS (
  SELECT
    usage_date,
    service_type,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used,
    credits_adjustment_cloud_services,
    credits_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
)
SELECT
  usage_date,
  service_type,
  credits_used_compute,
  credits_used_cloud_services,
  credits_used,
  credits_adjustment_cloud_services,
  credits_billed,

  /* Explicitly compute these too (helps explain billing to users) */
  (credits_used_cloud_services + credits_adjustment_cloud_services) AS billed_cloud_services_credits,

  /* A quick “is cloud services billed today?” signal */
  IFF((credits_used_cloud_services + credits_adjustment_cloud_services) > 0, TRUE, FALSE)
    AS is_cloud_services_billed
FROM src;
```

### Artifact: Native App billable event interface (pseudo-ADR)

**Decision:** Our FinOps app monetization should use **Custom Event Billing** events based on app-controlled actions (e.g., “cost optimization analysis run”, “recommendation export”, “scheduled report run”), not on telemetry/event-table counts.

**Reasoning (from Snowflake constraints):** Snowflake supports billable events emitted by calling `SYSTEM$CREATE_BILLING_EVENT(S)` within stored procedures; they do **not** support billing computed from event tables / UDF output / other activity sources.  
Source: [https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing](https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing)

**Implication:** We must define and version:
- `class` values
- `billing_quantity` semantics
- when we emit events (idempotency + retry behavior)
- a “pricing manifest” checked into git that mirrors the listing configuration (since listing only pays for configured events).  
Source: [https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model](https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model)

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Assuming we can attribute **warehouse** credits per query “exactly” | Users may demand per-query cost precision that Snowflake cannot provide deterministically when warehouses run concurrent queries | Be explicit in UI: per-query attribution is approximate unless using Snowflake-provided per-query attribution views (separate research). |
| METERING views have non-trivial **latency** | Near-real-time dashboards may show “missing” data, confusing users | Display “data freshness” banners; optionally compute max(usage_date/start_time) and show “latest available”. [metering_history docs](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history) |
| Billing-event classes drift from listing config | Provider doesn’t get paid for emitted events that aren’t configured | Add CI lint + runtime self-check endpoint that compares declared classes to a tracked config file (human maintained). [pricing models docs](https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model) |
| For apps with containers, consumers pay infra costs (compute pools) that we don’t control | Cost surprises and churn if we auto-provision compute pools or leave them running | Provide “suspend compute pools” guidance + in-app “compute pool state” surface; emphasize “no cost when suspended.” [container costs docs](https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance) |

---

## Links & Citations

1. `ACCOUNT_USAGE.METERING_HISTORY` docs: [https://docs.snowflake.com/en/sql-reference/account-usage/metering_history](https://docs.snowflake.com/en/sql-reference/account-usage/metering_history)
2. `ACCOUNT_USAGE.METERING_DAILY_HISTORY` docs: [https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history](https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history)
3. `ORGANIZATION_USAGE.METERING_DAILY_HISTORY` docs: [https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history](https://docs.snowflake.com/en/sql-reference/organization-usage/metering_daily_history)
4. Add billable events to a Native App (Custom Event Billing): [https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing](https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing)
5. Paid listings pricing models (Marketplace): [https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model](https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model)
6. Costs associated with apps with containers (SPCS): [https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance](https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance)

---

## Next Steps / Follow-ups

- Research **per-query** cost attribution options (e.g., `QUERY_ATTRIBUTION_HISTORY` vs warehouse metering heuristics) and decide what we can support in-product.
- Decide our initial **billable event taxonomy** (3–6 classes max) + write a repo-tracked “pricing manifest” file.
- Draft a “data freshness + latency” UX standard for all cost dashboards (hourly vs daily, account vs org views).
