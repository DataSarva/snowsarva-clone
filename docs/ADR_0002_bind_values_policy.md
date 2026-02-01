# ADR 0002 — Bind values (`QUERY_HISTORY.bind_values`) policy

- **Date:** 2026-02-01
- **Status:** Accepted

## Context
Snowflake 10.1 introduced GA support for retrieving bind variable values via:
- `INFORMATION_SCHEMA.BIND_VALUES`
- `bind_values` in query history outputs (`ACCOUNT_USAGE.QUERY_HISTORY`, `ORGANIZATION_USAGE.QUERY_HISTORY`, `QUERY_HISTORY`)

This can materially improve attribution and anomaly explanations for parameterized workloads, but it is privacy-sensitive and can include PII/secrets. Snowflake also allows disabling access via `ALLOW_BIND_VALUES_ACCESS = FALSE`.

## Decision
For our Snowflake FinOps Native App:

1) **MVP default: OFF**
- We will not ingest or persist bind values in MVP.
- MVP attribution relies on `QUERY_TAG`, object/warehouse tags, and metering/attribution history.

2) **Later: opt-in advanced mode**
If we add bind-values-based features, they must:
- be **explicitly enabled** by an account admin
- include in-product explanation + consent
- treat bind values as sensitive telemetry
- default to **redaction/hashing-first** (store only fingerprints/buckets unless explicitly configured)
- enforce strict retention + sampling

## Consequences
- Safer baseline product posture and easier security review.
- Slightly reduced “why did this parameterized query spike?” explainability until opt-in is enabled.
- We should still detect/report whether bind values are available (`ALLOW_BIND_VALUES_ACCESS`) and expose this as a health check in the UI.

## References
- Snowflake 10.1 release notes: https://docs.snowflake.com/en/release-notes/2026/10_1
- Bind variables docs (retrieve bind variable values + `ALLOW_BIND_VALUES_ACCESS`): https://docs.snowflake.com/en/sql-reference/bind-variables#retrieve-bind-variable-values
