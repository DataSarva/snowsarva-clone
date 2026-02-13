# Research: Native Apps - 2026-02-13

**Time:** 03:11 UTC  
**Topic:** Snowflake Native App Framework (+ Marketplace/listing observability)  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. Snowflake Native Apps **Shareback** is now **generally available**: a provider app can request consumer permission to share data back to the provider or to designated third parties via a governed channel. 
2. Snowflake added **listing and share observability** and released it as **generally available** with:
   - **Real-time** `INFORMATION_SCHEMA` objects (`LISTINGS`, `SHARES`, and `AVAILABLE_LISTINGS()`), and
   - **Historical (<= ~3h latency)** `ACCOUNT_USAGE` views (`LISTINGS`, `SHARES`, `GRANTS_TO_SHARES`) plus new listing/share DDL capture in `ACCOUNT_USAGE.ACCESS_HISTORY`.
3. Snowflake introduced a **Strong Authentication Hub** (Preview) to help accounts prepare for **single-factor password deprecation**, including readiness visibility, risk identification, and remediation guidance. Rollout is stated to complete by **Feb 20, 2026**.

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `<db>.INFORMATION_SCHEMA.LISTINGS` | INFO_SCHEMA view | Release note (Listing observability GA) | Real-time; doesn’t capture deleted objects. Provider-focused. |
| `<db>.INFORMATION_SCHEMA.SHARES` | INFO_SCHEMA view | Release note (Listing observability GA) | Real-time; consistent with `SHOW SHARES`; includes inbound + outbound. |
| `TABLE(<db>.INFORMATION_SCHEMA.AVAILABLE_LISTINGS(...))` | INFO_SCHEMA table function | Release note (Listing observability GA) | Consumer discovery; supports filters like `IS_IMPORTED => TRUE`. |
| `SNOWFLAKE.ACCOUNT_USAGE.LISTINGS` | ACCOUNT_USAGE view | Release note (Listing observability GA) | Historical analysis; includes dropped listings; <= ~3h latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.SHARES` | ACCOUNT_USAGE view | Release note (Listing observability GA) | Historical analysis; includes dropped shares; <= ~3h latency. |
| `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES` | ACCOUNT_USAGE view | Release note (Listing observability GA) | Tracks share grants, incl. historical grant/revoke. |
| `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` | ACCOUNT_USAGE view | Release note (Listing observability GA) | Now captures CREATE/ALTER/DROP on listings/shares + property diffs in `OBJECT_MODIFIED_BY_DDL` JSON. |

## MVP Features Unlocked

1. **Native App telemetry “shareback” lane (opt-in):** in the FinOps Native App, add a consumer-controlled toggle that (a) requests shareback permission and (b) shares back a curated dataset of cost/usage insights or app telemetry (e.g., detected inefficiencies, adoption metrics). This enables provider-side benchmarking and proactive recommendations while remaining governed.
2. **Marketplace/listing adoption dashboard:** use the new listing/share observability views to show:
   - which listings/shares exist, who has access (grants), and how this changes over time
   - alerts when a listing/share is modified or dropped (via `ACCOUNT_USAGE.ACCESS_HISTORY` DDL capture)
3. **Connected-app lifecycle auditing:** if/when we distribute the FinOps app via Marketplace, use the new views to build compliance evidence (“who had access to what share and when”) and drift detection.

## Concrete Artifacts

### SQL sketch: detect listing/share lifecycle events from ACCESS_HISTORY

```sql
-- NOTE: Validate column names/paths in your environment; this is a starting point.
-- Goal: audit CREATE/ALTER/DROP on listings and shares.

select
  event_timestamp,
  user_name,
  role_name,
  object_domain,
  object_name,
  object_modified_by_ddl
from snowflake.account_usage.access_history
where object_domain in ('LISTING', 'SHARE')
  and event_timestamp >= dateadd('day', -30, current_timestamp())
order by event_timestamp desc;
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Shareback mechanics depend on “app specifications” flows; exact implementation details (objects created, privileges, consent UX) may be more complex than the release note summary. | Could change app architecture for telemetry collection and opt-in flows. | Read full docs on “Request data sharing with app specifications” and prototype in a dev org. |
| New listing/share views may have role/privilege requirements and/or region/edition constraints. | Might limit what we can query from within an app or a given consumer account. | Verify required grants and availability in test accounts; confirm whether accessible within Native App runtime context. |
| Strong Authentication Hub is Preview + staged rollout. | Not reliable for automated checks in all accounts yet. | Confirm availability by Feb 20, 2026; check doc for any programmatic surfaces. |

## Links & Citations

1. Shareback GA release note (Feb 10, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-10-nativeapps-shareback
2. Listing/share observability GA release note (Feb 02, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga
3. Strong Authentication Hub (Preview) release note (Feb 12, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-02-12-strong-authentication-hub

## Next Steps / Follow-ups

- Read + summarize the Shareback implementation doc ("Request data sharing with app specifications") and decide the minimal consent + data model we’d use for a telemetry shareback MVP.
- Validate whether `INFORMATION_SCHEMA.LISTINGS/SHARES` and `ACCOUNT_USAGE.*` are queryable from within a Native App (or whether we need consumer-side setup). Document the required roles/grants.
