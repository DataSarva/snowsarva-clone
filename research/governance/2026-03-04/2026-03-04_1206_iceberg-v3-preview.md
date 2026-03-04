# Governance Research Note — Iceberg v3 support (Preview) in Snowflake (Mar 4, 2026)

- **When (UTC):** 2026-03-04 12:06
- **Scope:** Open table format feature update w/ governance + performance implications

## Accurate takeaways
- Snowflake announced **public preview support for Apache Iceberg™ v3** on **2026-03-04**.
- Snowflake v3 support includes additional **Iceberg data types**: `GEOGRAPHY`, `GEOMETRY`, `NANOSECOND`, `VARIANT`.
- Snowflake v3 support includes additional **features**:
  - **Default column values** for Iceberg tables.
  - **Deletion vectors** (position deletes) to improve write performance.
  - **Row lineage** for row-level governance/auditing.
- Snowflake states you can **read and write v3 Iceberg tables** (Snowflake-managed or externally managed) and that this support is **integrated across the platform** (ingestion, transformation, analytics, ML/AI, DR, external engines/catalogs, etc.).

## Data sources / audit views
- Not specified in the release note. (Follow-up: check whether row lineage surfaces in Snowflake via existing governance surfaces like Access History / Object Dependencies / Horizon / event tables; docs link suggests an Iceberg-specific governance mechanism.)

## MVP features unlocked (PR-sized)
1) **Iceberg capability detector**: in the FinOps/Governance app, add a check that flags accounts using Iceberg tables and whether they can leverage **v3 features** (default values, deletion vectors, row lineage) based on account edition/region/version. Output: “upgrade readiness” + recommended next actions.
2) **Write-optimization advisory**: add a heuristic that recommends **deletion vectors** for specific write-heavy Iceberg workloads (and warns about potential tradeoffs) with links to Snowflake docs.
3) **Governance/audit story**: add a “Lineage-ready tables” view for Iceberg tables (v3) and an audit checklist for enabling/validating **row lineage**.

## Risks / assumptions
- Preview features can have **behavior changes** before GA; performance/cost tradeoffs for deletion vectors may vary by workload.
- It’s unclear (from the release note alone) how row lineage is **queried/exported** and how it interacts with existing Snowflake governance products (Horizon, Access History). Needs doc validation.

## Links / references
- Release note: https://docs.snowflake.com/en/release-notes/2026/other/2026-03-04-iceberg-v3-support-preview
- Iceberg v3 support doc: https://docs.snowflake.com/en/user-guide/tables-iceberg-v3-specification-support
- Default values with Iceberg tables: https://docs.snowflake.com/en/user-guide/tables-iceberg-manage#label-tables-iceberg-default-values
- Deletion vectors: https://docs.snowflake.com/en/user-guide/tables-iceberg-manage#tables-iceberg-deletion-vectors
- Row lineage: https://docs.snowflake.com/en/user-guide/tables-iceberg-manage#label-tables-iceberg-row-lineage
