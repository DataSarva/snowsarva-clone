# Governance Research Note — Owner’s rights contexts introspection expansion (Preview 10.3)

- **When (UTC):** 2026-02-02 23:06
- **Scope:** RBAC / introspection / auditing in owner’s rights execution contexts (Native Apps, owner’s rights SPs, Streamlit)

## Accurate takeaways
- Snowflake **expanded the permission model for owner’s rights contexts** (explicitly including **owner’s rights stored procedures, Snowflake Native Apps, and Streamlit**) to allow broader **introspection**.
- In these owner’s rights contexts, **most `SHOW` and `DESCRIBE` commands are now permitted**.
  - **Exception:** commands that read domains tied to the current **session** or **user** remain blocked.
- In these owner’s rights contexts, **`INFORMATION_SCHEMA` views and table functions are now accessible**.
  - **Exception:** history functions remain restricted: `QUERY_HISTORY`, `QUERY_HISTORY_BY_*`, and `LOGIN_HISTORY_BY_USER`.
- This is documented as part of **Release 10.3 (Preview)**, scheduled for completion around **Feb 4, 2026** (subject to change), so availability may lag per-account until rollout completes.

## Data sources / audit views
- Newly allowed (in owner’s rights contexts):
  - `INFORMATION_SCHEMA.<views/table_functions>` (broadly)
  - Most `SHOW <object>` / `DESCRIBE <object>` operations
- Still restricted (explicitly called out):
  - `INFORMATION_SCHEMA.QUERY_HISTORY*` and other history functions listed in the release note

## MVP features unlocked (PR-sized)
1) **Native App self-diagnostics page (no extra grants)**: inside the app, run permitted `SHOW`/`DESCRIBE` + `INFORMATION_SCHEMA` queries to surface:
   - installed objects + versions
   - expected privileges/ownership mismatches
   - “is telemetry wired?” checks (e.g., existence of event tables, stage, integrations) without requiring the consumer to run manual SQL.
2) **Automated “RBAC readiness” scanner**: a stored procedure (owner’s rights) that inspects whether required objects exist and are configured correctly, then emits a structured report table for the UI.
3) **Environment inventory snapshot**: periodically persist a snapshot of allowed metadata (via `SHOW`/`DESCRIBE` + info schema) to support change detection and drift alerts.

## Risks / assumptions
- **Preview semantics:** final behavior/allowlist could change before GA; treat as feature-flagged and detect capability at runtime.
- **Still no history access:** the explicit restriction of query/login history functions means deep usage auditing may still require other sources (`ACCOUNT_USAGE`/`ORGANIZATION_USAGE`) and separate privileges.
- **Command-level edge cases:** “Most SHOW/DESCRIBE” implies some commands may still be blocked; we should implement graceful degradation and precise error reporting.

## Links / references
- Snowflake Release 10.3 (Preview): “Owner’s rights contexts: Allow INFORMATION_SCHEMA, SHOW, and DESCRIBE”
  - https://docs.snowflake.com/en/release-notes/2026/10_3
