# FinOps Research Note — Weekly Roadmap/Backlog Groom (Snowflake FinOps Native App)

- **When (UTC):** 2026-02-02 15:00
- **Scope:** FinOps / cost optimization
- **Why it matters (native app angle):** A clear phased roadmap keeps the Native App shippable while we build durable telemetry + attribution primitives that unlock ROI features (showback, waste detection, guardrails) without overreaching on data latency/privacy.

## Accurate takeaways
- The fastest path to provable ROI is **warehouse cost** (credits) + **query attribution** + **idle gap** handling: `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (billed) vs `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query credits).
- “Governance posture” improvements can be shown with configuration drift + guardrails coverage: warehouse `AUTO_SUSPEND`, resource monitors, and budgets (noting their refresh/latency constraints).
- Event Tables are a strong option for **app telemetry** and **telemetry ingest cost** attribution (via `TELEMETRY_DATA_INGEST`-related accounting), but should be treated as *Phase 1.5/2* once core FinOps facts are stable.

## Snowflake objects & data sources (verify in target account)
- **Cost / usage**
  - `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly-ish warehouse credits billed)
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` (per-query compute credits)
  - `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (dimensions + `QUERY_TAG`)
- **Attribution / tags**
  - `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` (+ `TAG_REFERENCES_ALL_COLUMNS` depending on account)
  - `INFORMATION_SCHEMA.TAG_REFERENCES` (if needed; account-scoped)
- **Guardrails**
  - Resource monitors (account objects; availability/latency to confirm)
  - Budgets (Snowflake Budgets objects; refresh latency to surface in UX)
- **Native App ops**
  - Maintenance policies (consumer-controlled maintenance windows; preview)
- **Telemetry (optional / Phase 2)**
  - Event Tables / `EVENTS_VIEW` and related telemetry cost views (need confirmation per account)

## MVP features unlocked (PR-sized)
1) **Cost Attribution v1 (showback)**: daily/monthly credits by cost center using (a) `QUERY_TAG`, (b) object tags via `TAG_REFERENCES`, with (c) optional idle-cost allocation.
2) **Idle Waste leaderboard**: warehouses ranked by “idle credits” = metered credits − query-attributed credits (with caveats).
3) **Warehouse guardrails check**: drift detection for `AUTO_SUSPEND`, `AUTO_RESUME`, multi-cluster min/max; and coverage view for resource monitors/budgets.

## Heuristics / detection logic (v1)
- **Idle credits (hourly)**: `WAREHOUSE_METERING_HISTORY.credits_used` − sum(`QUERY_ATTRIBUTION_HISTORY.credits_used_compute`) for the same warehouse/time bucket; clamp at >= 0; expose “unattributed/idle” bucket.
- **Showback attribution priority**:
  1) Query tag → cost_center (direct)
  2) Object tag (e.g., database/schema/table) if determinable from query metadata (MVP: best-effort)
  3) Unattributed (explicitly reported)
- **Idle allocation (optional)**: allocate warehouse idle credits proportionally to attributed query credits within the same bucket; else assign to “shared platform”.

## Security/RBAC notes
- Plan for a least-privilege “read-only” data collector role over `ACCOUNT_USAGE` views required for MVP; highlight expected latency (3–6h typical) in UI.
- Keep bind values opt-in only (already captured in ADR_0002). MVP attribution should not require bind values.

## Risks / assumptions
- Account Usage view latency and partial-hour refresh can confuse users; UI must label freshness and reconcile windows.
- `QUERY_ATTRIBUTION_HISTORY` coverage can vary (serverless, some features) and won’t represent *all* spend; need an “unattributed spend” section.
- Tagging standards differ wildly by customer; v1 should support lightweight mapping + allow manual overrides.

## Links / references
- (Internal) Research notes created 2026-02-01 to 2026-02-02 under `research/finops/` and `research/observability/`.
