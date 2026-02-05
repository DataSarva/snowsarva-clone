# Research: Native Apps - 2026-02-05

**Time:** 04:05 UTC  
**Topic:** Snowflake Native App Framework / FinOps telemetry surface area  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Snowflake 10.3 (Preview) expands what “owner’s rights contexts” can do**: owner’s-rights stored procedures, Native Apps, and Streamlit can now run **most SHOW/DESCRIBE** commands and access **INFORMATION_SCHEMA views & table functions**, with exceptions for some session/user-specific domains and history functions. 
2. The same 10.3 note explicitly calls out that **INFORMATION_SCHEMA is accessible**, but **history functions remain restricted**, including `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER`.
3. Snowflake announced **new ORGANIZATION_USAGE premium views** (feature update dated Feb 1, 2026). These expand the org-level telemetry surface for multi-account / org-level governance and (potentially) FinOps aggregation.
4. Snowflake added GA support for providers to **share “Connected Apps” in Snowflake Marketplace listings** (feature update dated Feb 2, 2026). This is relevant to distribution patterns, packaging, and how non-native “connected” experiences get attached to Marketplace listings.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| INFORMATION_SCHEMA (views + table functions) | Metadata surface | INFO_SCHEMA | Newly allowed in owner’s-rights contexts (10.3 preview), with stated restrictions on history functions. |
| SHOW / DESCRIBE (most) | Commands | N/A | Newly allowed in owner’s-rights contexts (10.3 preview), but not universally (exceptions exist). |
| QUERY_HISTORY / LOGIN_HISTORY* | Table functions | INFO_SCHEMA / ACCOUNT_USAGE* | Explicitly still restricted in owner’s-rights contexts per release note. (Exact object location depends on which interface/function you use.) |
| ORGANIZATION_USAGE premium views (new) | Usage/telemetry views | ORG_USAGE | New org-level premium telemetry views (details depend on the specific views in the release note). |

## MVP Features Unlocked

1. **In-app “self-diagnose” / “preflight checks” for Native Apps**: run SHOW/DESCRIBE and read INFORMATION_SCHEMA to verify consumer-side environment readiness (schemas, grants, references, versioning state), and generate a deterministic “what to fix” report.
2. **Native-App upgrade safety checks**: before applying upgrade directives / migrations, introspect target objects via INFORMATION_SCHEMA and SHOW to detect drift (missing columns, wrong types, missing privileges).
3. **Org-level FinOps collector improvements** (if the new ORG_USAGE premium views include cost/usage expansions you can leverage): add a new ingestion path for org-wide dashboards that don’t require per-account stitching.

## Concrete Artifacts

### Draft: Native App “preflight” stored procedure pattern

```sql
-- Pseudocode-ish: owner’s rights stored proc inside the app
-- Goal: minimal set of introspection checks that are now permitted.

CREATE OR REPLACE PROCEDURE app_admin.preflight()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  results VARIANT;
BEGIN
  -- Example checks (actual SHOW/DESCRIBE syntax and exact INFO_SCHEMA queries vary by object)
  -- SHOW WAREHOUSES;  -- if permitted
  -- SHOW GRANTS TO ROLE <role>;
  -- SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '...';

  results := OBJECT_CONSTRUCT(
    'timestamp', CURRENT_TIMESTAMP(),
    'checks', ARRAY_CONSTRUCT(
      OBJECT_CONSTRUCT('name','info_schema_access','status','unknown'),
      OBJECT_CONSTRUCT('name','show_describe_access','status','unknown')
    )
  );

  RETURN results;
END;
$$;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|---|---:|---|
| 10.3 is marked **Preview**; availability and exact behavior can change before completion. | Medium | Re-check when 10.3 is GA for target accounts; confirm via `CURRENT_VERSION()` and release completion. |
| “Most SHOW/DESCRIBE” includes exceptions; some admin-critical introspection may still be blocked. | Medium | Validate against specific SHOW/DESCRIBE statements we need for the app (warehouse, grants, roles, network policies, etc.). |
| New ORG_USAGE premium views might require additional entitlement/edition and may differ by region. | Medium | Open the Feb 1 release note and enumerate the exact view names + required privileges. |

## Links & Citations

1. Snowflake 10.3 Release Notes (Preview) — Owner’s rights contexts allow INFORMATION_SCHEMA, SHOW, and DESCRIBE: https://docs.snowflake.com/en/release-notes/2026/10_3
2. All release notes (for navigation to Feb 2026 feature updates): https://docs.snowflake.com/en/release-notes/all-release-notes
3. Feb 1, 2026 feature update — New ORGANIZATION_USAGE premium views: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views.html
4. Feb 2, 2026 feature update — Share Connected Apps in Marketplace listings (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-share-connected-apps-in-sfmarketplace-listings-ga

## Next Steps / Follow-ups

- Enumerate which specific SHOW/DESCRIBE statements are now allowed that matter for our app (grants, warehouses, databases/schemas, services, tasks).
- Pull the exact list of new ORG_USAGE premium view names and map them to Mission Control’s telemetry model.
- Decide whether to treat “Connected Apps in Marketplace listings” as a distribution channel we should support (or intentionally avoid) for the FinOps product.
