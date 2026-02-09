# Research: Native Apps - 2026-02-09

**Time:** 10:30 UTC  
**Topic:** Snowflake Native App Framework + FinOps-adjacent release notes (Feb 1–6, 2026)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Owner’s rights contexts now allow more introspection.** Snowflake expanded the permission model for **owner’s rights contexts** (explicitly including **Native Apps**) so that **most SHOW/DESCRIBE commands** are permitted, and **INFORMATION_SCHEMA views/table functions** are accessible, with some session/user-history exceptions.
2. **Listing/share observability is GA** via new **INFORMATION_SCHEMA** objects (real-time) and **ACCOUNT_USAGE** objects (≤ ~3h latency) for providers/consumers, plus **ACCESS_HISTORY** coverage for listing/share DDL.
3. **New ORGANIZATION_USAGE premium views** are rolling out (by Feb 9, 2026) to provide org-wide usage visibility, including **hourly credit metering** and **query-level cost attribution**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| INFORMATION_SCHEMA.LISTINGS | INFO_SCHEMA | Release note (GA) | Real-time listing metadata available to roles with access; does not capture deleted objects. |
| INFORMATION_SCHEMA.SHARES | INFO_SCHEMA | Release note (GA) | Share inventory analogous to `SHOW SHARES` (inbound + outbound). |
| INFORMATION_SCHEMA.AVAILABLE_LISTINGS() | INFO_SCHEMA (table function) | Release note (GA) | Consumer discovery; supports filters like `IS_IMPORTED => TRUE`. |
| ACCOUNT_USAGE.LISTINGS | ACCOUNT_USAGE | Release note (GA) | Historical listing rows (includes dropped listings), ≤ ~3h latency. |
| ACCOUNT_USAGE.SHARES | ACCOUNT_USAGE | Release note (GA) | Historical share rows (includes dropped shares), ≤ ~3h latency. |
| ACCOUNT_USAGE.GRANTS_TO_SHARES | ACCOUNT_USAGE | Release note (GA) | Historical grants/revokes to shares. |
| ACCOUNT_USAGE.ACCESS_HISTORY (listing/share DDL coverage) | ACCOUNT_USAGE | Release note (GA) | Now captures CREATE/ALTER/DROP on listings/shares + property deltas in `OBJECT_MODIFIED_BY_DDL`. |
| ORGANIZATION_USAGE.METERING_HISTORY | ORG_USAGE (premium) | Release note | Hourly credit usage per account across the org. |
| ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY | ORG_USAGE (premium) | Release note | Attributes compute costs to specific queries (warehouse compute) across the org. |

## MVP Features Unlocked

1. **Native App “self-diagnostics” (no extra privileges):** inside an owner’s-rights stored proc in the app, implement a diagnostics endpoint that runs permitted **SHOW/DESCRIBE** and reads relevant **INFORMATION_SCHEMA** objects to validate installation/config and produce a support bundle (redacting history functions that remain blocked).
2. **Marketplace / listing governance dashboard:** for providers, use **INFO_SCHEMA.LISTINGS** (real-time) + **ACCOUNT_USAGE.LISTINGS/SHARES/GRANTS_TO_SHARES** (history) to surface: listing state drift, who has access, grant changes, and listing lifecycle events.
3. **Org-wide FinOps drilldown (premium views present):** if available, add an optional org-account mode that uses **ORG_USAGE.METERING_HISTORY** + **ORG_USAGE.QUERY_ATTRIBUTION_HISTORY** to attribute spend to queries across accounts and highlight top cost drivers.

## Concrete Artifacts

### SQL sketches (starting points)

```sql
-- (Provider) Real-time listing inventory
SELECT *
FROM <db>.INFORMATION_SCHEMA.LISTINGS;

-- (Consumer) Discover listings available to this account
SELECT *
FROM TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS());

-- (Provider) Historical share grant changes
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES
WHERE SHARE_NAME ILIKE '%<your_share>%'
ORDER BY CREATED_ON DESC;

-- (Org account, premium) Org-wide hourly credits
SELECT *
FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_HISTORY
ORDER BY START_TIME DESC;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Owner’s-rights exceptions still block some SHOW/DESCRIBE and history functions | Diagnostics may fail for certain checks | Enumerate allowed commands in a sandbox and build graceful fallbacks. |
| INFO_SCHEMA listing/share objects may require specific grants/roles | App might not see expected rows | Document required privileges; detect “no access” vs “no data.” |
| ORG_USAGE premium views availability is gradual + premium licensing | FinOps features may not work for all customers | Feature-flag org-account mode; check view existence and fail soft. |

## Links & Citations

1. 10.3 release notes (Owner’s rights contexts update): https://docs.snowflake.com/en/release-notes/2026/10_3
2. Listing/share observability (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga
3. New ORGANIZATION_USAGE premium views: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views

## Next Steps / Follow-ups

- Confirm the exact set of SHOW/DESCRIBE commands permitted in owner’s-rights Native App contexts and record a compatibility matrix.
- Prototype a minimal “listing/share audit” schema + queries (INFO_SCHEMA + ACCOUNT_USAGE) for provider observability.
- Decide how to detect org-account presence + premium view availability at runtime (and how to explain requirements in-app).
