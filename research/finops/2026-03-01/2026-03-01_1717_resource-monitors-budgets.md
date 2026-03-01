# Research: FinOps - 2026-03-01

**Time:** 17:17 UTC  
**Topic:** Snowflake FinOps Cost Optimization  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake **resource monitors** can control/limit credit usage for **user-managed virtual warehouses** (and track associated cloud services for those warehouses), but **do not** track spending for **serverless features and AI services**; Snowflake docs explicitly recommend using a **budget** to monitor credit consumption for those features. (Resource monitors user guide)  
2. Resource monitor triggers (actions) are defined as **percent-of-credit-quota thresholds**, and **thresholds > 100% are supported**. Available actions include `NOTIFY`, `SUSPEND` (waits for running queries to finish), and `SUSPEND_IMMEDIATE` (cancels running statements). (Resource monitors user guide; CREATE RESOURCE MONITOR)  
3. Notifications from resource monitors are **disabled by default** and must be explicitly enabled in user preferences; email delivery requires a **verified email**. (Resource monitors user guide; CREATE RESOURCE MONITOR)  
4. `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` exposes monitor configuration and “current cycle” fields like `CREDIT_QUOTA`, `USED_CREDITS`, and trigger threshold columns (`NOTIFY`, `SUSPEND`, `SUSPEND_IMMEDIATE`), but the view can have up to **~120 minutes latency**. (ACCOUNT_USAGE RESOURCE_MONITORS view)  
5. Snowflake’s cost docs state that the cloud services layer consumes credits, but **billing** for cloud services is only applied when daily cloud services consumption **exceeds 10%** of daily virtual warehouse usage; however, many views/dashboards show **consumed** credits without applying this “10% adjustment”, and Snowflake recommends using `METERING_DAILY_HISTORY` to determine credits actually billed. (Exploring compute cost)

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS` | View | `ACCOUNT_USAGE` | Lists monitors + quota/usage + thresholds; latency up to ~120 minutes. |
| `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | `ACCOUNT_USAGE` | Used for compute breakdowns and cloud-services ratios in Snowflake’s “Exploring compute cost” examples; consumed credits. |
| `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | `ACCOUNT_USAGE` | Recommended in docs for “credits actually billed” (includes cloud services adjustment). |
| `SHOW WAREHOUSES` | Command | N/A | Output includes each warehouse’s `resource_monitor` assignment (docs show this in examples). |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Resource Monitor Coverage & Drift panel**: list all warehouses, whether they have a monitor assigned, monitor `LEVEL` (account vs warehouse), quota, thresholds, and “% used” + “time-to-quota” projection (simple extrapolation over last N days).
2. **Guardrail linting**: warn on common unsafe configurations from docs (e.g., no buffer thresholds, multi-warehouse monitors causing cross-impact, no actions defined, notifications not enabled/verified). Include “recommended defaults” like 90% `SUSPEND` + 100% `SUSPEND_IMMEDIATE` pattern.
3. **Consumed vs billed compute reconciliation widget**: show (a) consumed credits by warehouses + cloud services ratios and (b) billed credits from `METERING_DAILY_HISTORY`, with explicit UI labeling (“consumed” vs “billed”) so FinOps users don’t misinterpret.

## Concrete Artifacts

*SQL drafts, ADRs, schemas, pseudocode, etc.*

### Resource monitor + warehouse coverage report (SQL draft)

Goal: a single query the Native App can run to produce a coverage dashboard.

```sql
-- Coverage report for warehouses ↔ resource monitors
-- Sources:
--   - RESOURCE_MONITORS: https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors
--   - Resource monitors guide: https://docs.snowflake.com/en/user-guide/resource-monitors

WITH rms AS (
  SELECT
      NAME                          AS resource_monitor_name,
      LEVEL                         AS resource_monitor_level,
      CREDIT_QUOTA                  AS credit_quota,
      USED_CREDITS                  AS used_credits,
      REMAINING_CREDITS             AS remaining_credits,
      NOTIFY                        AS notify_pct,
      SUSPEND                       AS suspend_pct,
      SUSPEND_IMMEDIATE             AS suspend_immediate_pct,
      WAREHOUSES                    AS warehouses_csv,
      OWNER                         AS owner_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS
),
warehouses AS (
  -- SHOW WAREHOUSES has to run as a command; in an app, you can capture it via RESULT_SCAN.
  -- Keeping this as a pattern the app can execute.
  SELECT
      "name"::STRING               AS warehouse_name,
      "resource_monitor"::STRING   AS resource_monitor_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
)
SELECT
  w.warehouse_name,
  w.resource_monitor_name,
  r.resource_monitor_level,
  r.credit_quota,
  r.used_credits,
  CASE
    WHEN r.credit_quota IS NULL THEN NULL
    ELSE (r.used_credits::FLOAT / NULLIF(r.credit_quota::FLOAT, 0))
  END                              AS pct_quota_used,
  r.notify_pct,
  r.suspend_pct,
  r.suspend_immediate_pct,
  r.owner_role
FROM warehouses w
LEFT JOIN rms r
  ON r.resource_monitor_name = w.resource_monitor_name
ORDER BY
  pct_quota_used DESC NULLS LAST,
  warehouse_name;
```

**Implementation note (Native App):** run `SHOW WAREHOUSES;` first, then wrap `RESULT_SCAN(LAST_QUERY_ID())` to turn the output into a relation.

### “High cloud services ratio” detector (SQL draft)

This is adapted from Snowflake’s own “Exploring compute cost” example query (“Warehouses with high cloud services usage”).

```sql
-- Source: https://docs.snowflake.com/en/user-guide/cost-exploring-compute
SELECT
  warehouse_name,
  SUM(credits_used)                 AS credits_used,
  SUM(credits_used_cloud_services)  AS credits_used_cloud_services,
  SUM(credits_used_cloud_services) / NULLIF(SUM(credits_used), 0) AS percent_cloud_services
FROM snowflake.account_usage.warehouse_metering_history
WHERE TO_DATE(start_time) >= DATEADD(month, -1, CURRENT_TIMESTAMP())
  AND credits_used_cloud_services > 0
GROUP BY 1
ORDER BY 4 DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| `ACCOUNT_USAGE.RESOURCE_MONITORS` can lag by up to ~120 minutes. | Dashboards/alerts can be stale; “% used” might appear behind reality. | Confirm in target account by comparing `SHOW RESOURCE MONITORS` output vs view, and/or observe changes + time-to-visibility. |
| Users often interpret “credits consumed” as “credits billed”, but Snowflake applies a daily cloud services adjustment (10% rule). | Over/under-stating actual billed compute; wrong chargeback. | Follow Snowflake guidance: use `METERING_DAILY_HISTORY` for billed totals; label “consumed vs billed” explicitly in UI. |
| Non-admin notification behaviors/limitations (e.g., non-admin users only on warehouse monitors; notifications must be enabled). | Teams may think monitors are broken when no email appears. | Add “notification readiness” checklist in app; link to Snowflake steps to enable notifications & verify email. |

## Links & Citations

1. https://docs.snowflake.com/en/user-guide/resource-monitors
2. https://docs.snowflake.com/en/sql-reference/sql/create-resource-monitor
3. https://docs.snowflake.com/en/sql-reference/account-usage/resource_monitors
4. https://docs.snowflake.com/en/user-guide/cost-exploring-compute
5. https://docs.snowflake.com/en/user-guide/cost-understanding-compute

## Next Steps / Follow-ups

- Pull the **Budgets** docs explicitly and map: (a) which objects/features are budget-supported vs not, and (b) the app’s decision tree for “use budget vs use resource monitor” guardrails.
- Decide the app’s **canonical cost guardrail model**: {warehouse monitors + account monitor} + {budgets for serverless/AI services} with a unified “guardrail coverage” UX.
