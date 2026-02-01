# ADR 0001 — Telemetry v0 scope (consumer + provider)

- **Date:** 2026-02-01
- **Status:** Accepted

## Context
We need an observability/FinOps telemetry backbone for a Snowflake Native App. Snowflake Event Tables provide an OpenTelemetry-aligned schema. Native Apps also support provider-side event sharing, but require provider setup (event account + active event table per region) *before* consumer installs, or events may be discarded.

## Decision
We will implement telemetry as a **two-mode** system:

1) **Consumer-only (default v0)**
- All core product value (FinOps attribution + self-observability + local recommendations) must work without provider event sharing.
- Use `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` (or the active event table) to compute local facts.

2) **Provider triage (optional)**
- When provider event sharing is correctly configured, we also compute provider-side aggregate facts (per consumer/app version), enabling support/triage dashboards.
- We treat deep correlation to consumer spend as **best-effort/opt-in** because query/database identifiers may be hashed.

## Consequences
- We must ship an in-app "Telemetry Health" check with remediation guidance.
- We must include a telemetry level/sampling config to control cost.
- We prioritize an explainable, low-volume signal layer (15m/1h windows) over raw event retention.
- **Bind values policy (MVP):** we do **not** ingest `bind_values` by default. If we support bind values at all, it is **explicit opt-in** with clear UI copy + redaction/hashing-first handling, because it is privacy-sensitive and gated by `ALLOW_BIND_VALUES_ACCESS`.
