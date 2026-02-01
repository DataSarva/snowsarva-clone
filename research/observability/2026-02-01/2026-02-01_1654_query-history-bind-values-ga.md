# Observability Research Note — `QUERY_HISTORY.bind_values` + `INFORMATION_SCHEMA.BIND_VALUES` (GA in 10.1)

- **When (UTC):** 2026-02-01 16:54
- **Scope:** query-level observability for parameterized SQL (cost/perf attribution, troubleshooting)

## Accurate takeaways
- Snowflake server release **10.1 (Jan 19–23, 2026)** made “retrieve bind variable values” **generally available**.
- Bind variable values can be retrieved in two ways:
  - `INFORMATION_SCHEMA.BIND_VALUES` table function.
  - `bind_values` column exposed in query history outputs: **ACCOUNT_USAGE.QUERY_HISTORY**, **ORGANIZATION_USAGE.QUERY_HISTORY**, and the `QUERY_HISTORY` function.
- Access to bind values can be disabled via account-level parameter **`ALLOW_BIND_VALUES_ACCESS = FALSE`**.

## Telemetry schema ideas
- Add an optional column to our query fact table:
  - `bind_values_variant` (VARIANT) — populated only when the account allows it.
- Derive two fingerprints:
  - `statement_hash` (existing Snowflake hash / normalized statement)
  - `param_fingerprint` (e.g., stable hash of bind values after coarse bucketing) to cluster “same query, different parameter regimes”.

## MVP features unlocked (PR-sized)
1) **Privacy-aware settings panel**: detect/report `ALLOW_BIND_VALUES_ACCESS` and keep bind-value ingestion off by default; provide a one-click opt-in.

## Post-MVP features (opt-in)
1) **“Expensive parameter regimes” card**: for a given query signature, show top N bind-value buckets associated with high credits/time.
2) **Better anomaly explanations**: when a cost spike is from a known statement, include *which parameters* drove the spike (when allowed).

## Risks / assumptions
- **Privacy / secrets risk**: bind values can include PII or sensitive literals; we must treat this as sensitive telemetry and keep it opt-in.
- **Role/visibility nuance**: availability depends on permissions + account parameter; assume we may not be able to read bind values in many customer accounts.
- **Data volume**: bind values can bloat query history storage/ETL; we likely need sampling, bucketing, and strict retention.

## Links / references
- Snowflake 10.1 release notes (behavior changes): https://docs.snowflake.com/en/release-notes/2026/10_1
- Bind variables docs (retrieve bind variable values + `ALLOW_BIND_VALUES_ACCESS`): https://docs.snowflake.com/en/sql-reference/bind-variables#retrieve-bind-variable-values
