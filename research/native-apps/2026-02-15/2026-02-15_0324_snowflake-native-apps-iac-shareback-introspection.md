# Research: Native Apps - 2026-02-15

**Time:** 0324 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Inter-app communication (Preview)**: A Snowflake Native App can now securely communicate with other Native Apps in the *same consumer account*, enabling sharing/merging data across apps. (Preview as of 2026-02-13.)
2. **Shareback (GA)**: A Native App can request consumer permission to share data back to the provider (or designated third parties), enabling governed telemetry/analytics, compliance reporting, and preprocessing workflows. (GA as of 2026-02-10.)
3. **Owner’s-rights introspection expanded** (applies to Native Apps): Owner’s-rights contexts now allow most `SHOW` / `DESCRIBE` commands and allow access to `INFORMATION_SCHEMA` views + table functions; some history functions remain restricted (e.g., `QUERY_HISTORY*`, `LOGIN_HISTORY_BY_USER`). (Server release 10.3.)
4. **FinOps-adjacent (Org-level)**: New ORGANIZATION_USAGE premium views include hourly per-account metering and query-level cost attribution across org accounts, rolling out through 2026-02-09.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `INFORMATION_SCHEMA` views / table functions | Metadata | Server release 10.3 notes | Now accessible from owner’s-rights contexts (with exceptions for some history functions). |
| `SHOW` / `DESCRIBE` (most) | Metadata | Server release 10.3 notes | Now permitted in owner’s-rights contexts; still blocked for certain session/user domains. |
| `ORGANIZATION_USAGE.METERING_HISTORY` | ORG_USAGE (premium) | Feb 01, 2026 feature update | Hourly credit usage per account in org. |
| `ORGANIZATION_USAGE.QUERY_ATTRIBUTION_HISTORY` | ORG_USAGE (premium) | Feb 01, 2026 feature update | Attributes compute costs to specific queries on warehouses across org. |

## MVP Features Unlocked

1. **Provider-grade telemetry pipeline (now “official”)**: Use Shareback (GA) to request explicit permission to export structured telemetry/cost insights from consumer → provider, rather than relying on “bring your own share” patterns.
2. **Native App diagnostics that don’t require extra grants**: In owner’s-rights procedures, leverage broader `SHOW`/`DESCRIBE` + `INFORMATION_SCHEMA` access to power an “App Health” page (object presence, privilege checks, config drift) without asking users for additional roles.
3. **Composable multi-app suite** (Preview): For a portfolio of Native Apps (e.g., cost optimization app + governance app), use inter-app comm to share intermediate artifacts (labels, classifications, anomaly signals) inside the consumer account.

## Concrete Artifacts

### Draft: “App Health” introspection checklist (owner’s-rights)

Focus: run from within owner’s-rights stored procs used by the app.

- `SHOW WAREHOUSES` / `SHOW ROLES` / `SHOW GRANTS` (as permitted) to detect missing dependencies
- `SELECT ... FROM <db>.INFORMATION_SCHEMA.*` to validate required objects exist
- Avoid restricted history functions (`QUERY_HISTORY*`, `LOGIN_HISTORY_BY_USER`) per 10.3 notes

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Inter-app communication is **Preview** (API + permissions may change). | Could require refactor or feature flagging. | Track the linked “Inter-app Communication” developer guide + GA announcement. |
| Shareback requires explicit consumer permission and may have Marketplace/listing workflow implications. | Adoption friction; need clear UX + docs. | Read the “Request data sharing with app specifications” doc and confirm required listing metadata + consent UX. |
| ORG_USAGE premium views availability/entitlement varies. | Feature may not be usable for all customers. | Confirm premium views access in target customer tiers; detect availability programmatically. |

## Links & Citations

1. Feb 13, 2026: Native Apps — Inter-App Communication (Preview): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-13-nativeapps-iac
2. Feb 10, 2026: Native Apps — Shareback (GA): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
3. 10.3 release notes (Owner’s rights contexts allow `INFORMATION_SCHEMA`, `SHOW`, `DESCRIBE`): https://docs.snowflake.com/en/release-notes/2026/10_3
4. Feb 01, 2026: New ORGANIZATION_USAGE premium views: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-01-organization-usage-new-views

## Next Steps / Follow-ups

- Pull and summarize the linked developer-guide pages for (a) inter-app communication and (b) shareback app specs, to confirm exact APIs/objects.
- Add a feature flag plan:
  - `shareback_enabled` (GA) → default on when user consents
  - `inter_app_comm_enabled` (Preview) → default off
- Prototype “App Health” stored proc that only uses permitted commands/views in owner’s-rights contexts (per 10.3 constraints).
