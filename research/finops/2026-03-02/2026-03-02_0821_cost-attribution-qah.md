# Research: FinOps - 2026-03-02

**Time:** 08:21 UTC  
**Topic:** Snowflake FinOps Cost Attribution (Object Tags + Query Tags + QUERY_ATTRIBUTION_HISTORY)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake recommends attributing cost using **object tags** (tag resources/users) and **query tags** (tag queries), depending on whether resources are dedicated, shared across users, or shared via an application issuing queries on behalf of multiple cost centers. 
2. For SQL-based cost attribution **within an account**, Snowflake explicitly calls out `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`, `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, and `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` as key sources. 
3. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` provides **per-query compute cost attribution** (warehouse credits attributed to queries), but **does not include** storage, data transfer, cloud services, serverless feature costs, AI token costs, etc.; and it also **excludes warehouse idle time** (idle time is measurable at the warehouse level).
4. `SNOWFLAKE.ACCOUNT_USAGE` views have **data latency** (varies by view; commonly 45 minutes to 3 hours, and some views such as `QUERY_ATTRIBUTION_HISTORY` can be higher), and have **longer retention** than corresponding `INFORMATION_SCHEMA` views (e.g., historical usage views retained for ~1 year). 
5. For overall spend in currency across an org, Snowflake provides `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` and shows example rollups by account; in Snowsight, cost information can take up to ~72 hours to become available and is shown in UTC.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` | View | `ACCOUNT_USAGE` | Tag inventory / object tagging; join key varies by domain (e.g., warehouse uses `object_id` = `warehouse_id`). |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Warehouse credit usage, used for billed compute by warehouse; used in cost attribution joins. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | View | `ACCOUNT_USAGE` | Per-query compute credits attribution; excludes idle time and non-compute categories; no org-wide equivalent per docs. |
| `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` | View | `ACCOUNT_USAGE` | Query metadata including `QUERY_TAG`; useful when you can’t use `QUERY_ATTRIBUTION_HISTORY` or need richer query context. |
| `SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | View | `ORG_USAGE` | Organization-level rollups in currency (requires org context/role access patterns). |
| `SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ORG_USAGE` | Organization-level warehouse metering (compute) across accounts; can be joined to org-level `TAG_REFERENCES` in org account. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **“Tag Coverage” FinOps health check**: daily job that reports % of warehouses/users/databases/schemas untagged (and “top spend among untagged”). This directly supports tag-enforcement workflows.
2. **Attribution model switch**: implement two attribution modes in the app:
   - Dedicated resources → join `WAREHOUSE_METERING_HISTORY` to `TAG_REFERENCES` on warehouse tags.
   - Shared warehouses → use `QUERY_ATTRIBUTION_HISTORY` grouped by `QUERY_TAG` (or user tags) and optionally distribute idle time.
3. **Explainability panel**: for a cost center and time window, show:
   - billed warehouse credits (`WAREHOUSE_METERING_HISTORY`)
   - attributed query credits (`QUERY_ATTRIBUTION_HISTORY`)
   - “unattributed/idle gap” = billed - attributed (explain why: idle time + excluded cost categories).

## Concrete Artifacts

### SQL Draft: Monthly compute credits by cost_center tag (dedicated warehouses)

Based on the documented join pattern (warehouse metering + tag references), here’s a hardened version that:
- handles missing tags (`untagged`)
- filters explicitly to domain `WAREHOUSE`
- selects explicit columns (avoid `SELECT *` on Snowflake-provided views)

```sql
-- Monthly compute credits by warehouse cost_center tag
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY + TAG_REFERENCES

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS month_start,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS month_end
)
SELECT
  tr.tag_name,
  COALESCE(tr.tag_value, 'untagged') AS tag_value,
  SUM(wmh.credits_used_compute) AS total_credits_used_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  ON wmh.warehouse_id = tr.object_id
 AND tr.domain = 'WAREHOUSE'
CROSS JOIN params p
WHERE wmh.start_time >= p.month_start
  AND wmh.start_time <  p.month_end
GROUP BY 1, 2
ORDER BY total_credits_used_compute DESC;
```

### SQL Draft: Compute credits by QUERY_TAG using QUERY_ATTRIBUTION_HISTORY (shared warehouses)

```sql
-- Monthly compute credits by query_tag (excluding idle time by definition)
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY

WITH params AS (
  SELECT
    DATE_TRUNC('MONTH', DATEADD(MONTH, -1, CURRENT_DATE())) AS month_start,
    DATE_TRUNC('MONTH', CURRENT_DATE()) AS month_end
)
SELECT
  COALESCE(NULLIF(query_tag, ''), 'untagged') AS query_tag,
  SUM(credits_attributed_compute) AS compute_credits,
  SUM(credits_used_query_acceleration) AS qas_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
CROSS JOIN params p
WHERE start_time >= p.month_start
  AND start_time <  p.month_end
GROUP BY 1
ORDER BY compute_credits DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `QUERY_ATTRIBUTION_HISTORY` excludes idle time and several non-compute categories (storage, transfer, cloud services, serverless features, AI token costs). | “Compute showback” won’t equal bill; users may think the app is wrong. | Add an explicit “coverage/exclusions” explainer and compute reconciliation metrics (billed vs attributed) in UI. Source explicitly lists exclusions. |
| Data latency varies across `ACCOUNT_USAGE` views (and Snowsight can lag). | Dashboards/alerts may appear “late” or inconsistent for recent windows. | Document expected lag per view; in UI, label the freshest timestamp available; avoid tight SLAs on last 1–3 hours. |
| Org-wide attribution for queries has no org-wide equivalent of `QUERY_ATTRIBUTION_HISTORY` (per docs). | Multi-account rollups may be limited to warehouse-level costs, not per-query across org. | Confirm in `ORGANIZATION_USAGE` docs; design multi-account features around warehouse metering + tags, and keep per-query analysis per-account. |
| Role/privilege requirements (SNOWFLAKE database roles / imported privileges) may block access to required views. | App onboarding friction; partial data. | Ship a “permissions preflight” that checks access to specific views and provides exact grants/roles needed. |

## Links & Citations

1. Snowflake docs: Attributing cost (object tags + query tags, and examples using TAG_REFERENCES, WAREHOUSE_METERING_HISTORY, QUERY_ATTRIBUTION_HISTORY) — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: Account Usage overview (latency/retention; view inventory including QUERY_ATTRIBUTION_HISTORY) — https://docs.snowflake.com/en/sql-reference/account-usage
3. Snowflake docs: Exploring overall cost (Snowsight notes; org-level currency view example `USAGE_IN_CURRENCY_DAILY`) — https://docs.snowflake.com/en/user-guide/cost-exploring-overall
4. Snowflake Well-Architected Framework: Cost Optimization + FinOps (tagging, visibility/control principles; links to TAG_REFERENCES etc.) — https://www.snowflake.com/en/developers/guides/well-architected-framework-cost-optimization-and-finops/

## Next Steps / Follow-ups

- Pull `ORGANIZATION_USAGE` docs next to confirm exactly which org-wide cost + tag views exist (and any limitations/latencies).
- Draft a small ADR: “Compute showback model” (billed warehouse credits vs attributed query credits; how we present the gap).
- Prototype a permissions preflight routine for Native App install (checks: `TAG_REFERENCES`, `WAREHOUSE_METERING_HISTORY`, `QUERY_ATTRIBUTION_HISTORY`, `USAGE_IN_CURRENCY_DAILY`).
