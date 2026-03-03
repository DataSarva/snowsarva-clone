# Research: FinOps - 2026-03-03

**Time:** 20:50 UTC  
**Topic:** Snowflake FinOps Cost Optimization (cost attribution + tag-based budgets; Native App implications)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

*Plain statements validated from sources. No marketing language.*

1. Snowflake’s documented approach to cost attribution is: use **object tags** to associate users/resources to cost centers, and use **query tags** when an application executes queries on behalf of multiple cost centers. (Snowflake docs) [1]
2. Within an account, Snowflake documents cost attribution queries that join **SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES** with **WAREHOUSE_METERING_HISTORY** (warehouse totals) and/or **QUERY_ATTRIBUTION_HISTORY** (per-query attributed compute credits). (Snowflake docs) [1]
3. **Custom budgets** can monitor compute costs for a custom group of objects either by (a) adding a **tag/value pair** to the budget or (b) adding objects individually; objects included multiple ways count only once toward the limit. (Snowflake docs) [2]
4. When a tag is changed on an object, Snowflake notes it can take **up to six hours** for the change to be reflected in budgets that use tags. (Snowflake docs) [2]
5. Snowflake’s budget method **`<budget_name>!ADD_TAG` is deprecated**; the docs direct users to use **`<budget_name>!ADD_RESOURCE_TAG`** instead. (Snowflake docs) [3]
6. Snowflake states that when a tag is added to a budget, the budget tracks objects with that tag, including **inherited tags**; overriding a tag value at a lower level can exclude the object from the budget. (Snowflake docs) [2]
7. Snowflake’s Custom Budgets documentation includes explicit behavior for **Snowflake Native Apps**:
   - If you add an app to a budget **using tags**, only **warehouses** with the matching tag/value are tracked automatically.
   - If you add an app to a budget **directly**, objects that consume credits and are **created and owned by the app** are added automatically (including app-owned warehouses and SCS compute pools). Shared warehouses/compute pools are not tracked automatically. (Snowflake docs) [2]
8. Snowflake’s engineering blog describes “tag-based budgets” as budgets that monitor a tag and refresh multiple times a day, with updates reflecting within hours and backfilling for the current month. (Snowflake engineering blog) [4]

## Snowflake Objects & Data Sources

| Object/View / Concept | Type | Source | Notes |
|---|---|---|---|
| SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES | View | ACCOUNT_USAGE | “What has what tags” for objects/users; used for attribution joins. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY | View | ACCOUNT_USAGE | Warehouse credit usage totals; used for showback by warehouse and for idle/billed reconciliation. [1] |
| SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY | View | ACCOUNT_USAGE | Per-query attributed compute credits (excludes idle time); used for query-tag or user-tag allocation. [1] |
| Custom Budgets (SNOWFLAKE.CORE.BUDGET) | Class/Object | Snowflake Core | Can monitor compute costs for a group of objects; supports tag/value inclusion. [2] |
| Budget method `!ADD_TAG` (deprecated) | Method | Snowflake Core | Use `!ADD_RESOURCE_TAG` instead. [3] |
| SHOW WAREHOUSES.owner_role_type = 'APPLICATION' | Show cmd | Account metadata | Used to determine if a warehouse is owned by a Native App. [2] |
| SHOW COMPUTE POOLS.application is not NULL | Show cmd | Account metadata | Used to determine if a compute pool is owned by a Native App. [2] |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

*PR-sized ideas that can be shipped based on these findings.*

1. **Budget-aware attribution UX (Native App):** surface “budget scope lag” and “budget inclusion logic” directly in the UI:
   - For each cost center tag/value, show whether the admin is using **custom budgets** vs pure reporting.
   - When tags changed < 6h ago, display a “budget may not reflect changes yet” banner. (Because Snowflake explicitly documents up to 6h.) [2]
2. **Native App cost guardrail advisor:** detect when admins are relying on deprecated budget APIs (or legacy docs) and recommend `ADD_RESOURCE_TAG` (not `ADD_TAG`) plus required privilege checklist (`APPLYBUDGET`, instance roles). [3]
3. **App-owned vs shared compute classification:** add a rule-based classifier (from `SHOW WAREHOUSES` / `SHOW COMPUTE POOLS`) to label spend as:
   - `app_owned` (owner_role_type/application populated)
   - `shared` (not owned by app)
   Then recommend whether to add the app directly or tag shared resources for budget coverage. [2]

## Concrete Artifacts

### Artifact: “FinOps tagging + budget coverage” daily mart query (SQL draft)

Goal: create a daily table for the Native App that highlights (a) tagged vs untagged warehouse credits and (b) recently-changed tags that may not have propagated into budgets yet.

```sql
-- FINOPS: daily warehouse credits by cost_center tag (showback) + untagged bucket
-- Source: SNOWFLAKE.ACCOUNT_USAGE.{WAREHOUSE_METERING_HISTORY, TAG_REFERENCES}
-- Based on the documented join pattern for attributing costs by warehouse tag. [1]

WITH wh_credits AS (
  SELECT
    warehouse_id,
    warehouse_name,
    start_time::date AS usage_date,
    SUM(credits_used_compute) AS credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY 1,2,3
),
wh_tags AS (
  SELECT
    object_id AS warehouse_id,
    tag_name,
    tag_value,
    -- Optional: use apply_method / level if you want to explain inheritance/propagation.
    -- (apply_method exists on tag reference functions/views per tagging docs; validate availability in your edition.)
    domain
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'WAREHOUSE'
    AND UPPER(tag_name) = 'COST_CENTER'
)
SELECT
  w.usage_date,
  w.warehouse_name,
  COALESCE(t.tag_value, 'untagged') AS cost_center,
  SUM(w.credits_used_compute) AS credits_used_compute
FROM wh_credits w
LEFT JOIN wh_tags t
  ON w.warehouse_id = t.warehouse_id
GROUP BY 1,2,3
ORDER BY 1 DESC, 4 DESC;
```

### Artifact: Budget API modernization note (mini-ADR)

**Decision:** Treat `!ADD_TAG` as legacy and generate all examples + guidance using `!ADD_RESOURCE_TAG`.

**Rationale:** Snowflake explicitly marks `!ADD_TAG` as deprecated and points to `!ADD_RESOURCE_TAG`. [3]

**Implication for the Native App:**
- When we generate “copy-paste” SQL for customers, only generate `!ADD_RESOURCE_TAG` flows.
- When we parse customer-provided scripts (optional future feature), warn if `!ADD_TAG` is present.

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---|---|
| Budgets refresh/propagation timing may vary by account and “low latency budget” settings. | UI could over/under-warn about freshness. | Validate empirically by changing a tag and observing time-to-reflection; docs say up to 6h. [2] |
| Native App can’t programmatically create/modify budgets in customer accounts (likely restricted by privileges/ownership patterns). | App may need to remain “advisor/reporting” rather than “enforcer.” | Confirm via Native App framework capabilities + required privileges for budgets in target customer accounts. [2][3] |
| App-owned vs shared resource detection relies on `SHOW` outputs and columns (e.g., `owner_role_type`, `application`). | Classifier might break if Snowflake changes output schema. | Validate against current `SHOW` output in a test account; keep parsing tolerant. [2] |

## Links & Citations

1. Snowflake docs: Attributing cost — https://docs.snowflake.com/en/user-guide/cost-attributing
2. Snowflake docs: Custom budgets — https://docs.snowflake.com/en/user-guide/budgets/custom-budget
3. Snowflake docs: `<budget_name>!ADD_TAG` (deprecated) — https://docs.snowflake.com/en/sql-reference/classes/budget/methods/add_tag
4. Snowflake engineering blog: Tag-based budgets / cost attribution — https://www.snowflake.com/en/engineering-blog/tag-based-budgets-cost-attribution/

## Next Steps / Follow-ups

- Pull the `ADD_RESOURCE_TAG` method docs and confirm exact privileges + examples (since `ADD_TAG` is deprecated). (Likely: https://docs.snowflake.com/.../add_resource_tag)
- Convert the “app-owned vs shared spend” classifier into a concrete ruleset + unit tests (based on `SHOW` outputs).
- Add a UI spec for “budget freshness” and “tag-change detection” (what signals we can use without requiring elevated privileges).
