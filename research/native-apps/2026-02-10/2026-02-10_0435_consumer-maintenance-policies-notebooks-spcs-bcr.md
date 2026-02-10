# Research: Native Apps - 2026-02-10

**Time:** 04:35 UTC  
**Topic:** Snowflake Native App Framework  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Native Apps now support consumer-controlled maintenance policies (public preview)** that can delay an app upgrade until a consumer-defined start date/time window. (This kicks in after the provider sets a new release directive.)
2. Consumers manage these upgrade windows via **`CREATE MAINTENANCE POLICY`** and **`ALTER MAINTENANCE POLICY`**. The release note explicitly positions this for controlling when app upgrades are allowed to begin.
3. **Notebooks in Workspaces is GA** and runs on a **container runtime powered by Snowpark Container Services (SPCS)**, with explicit compute/cost-management features like idle-time configuration, background kernel persistence, shared connections, CPU/GPU compute pools, and workspace-level External Access Integration (EAI) management.
4. In the **2026_01 behavior change bundle (pending)**, deleting an SPCS **block volume** via certain operations (e.g., `DROP SERVICE ... FORCE`, `ALTER COMPUTE POOL ... STOP ALL`) will first **create snapshots** retained for **7 days by default**, and **those snapshots are billable**. There is an explicit **opt-out** via `snapshotOnDelete: false` in the service spec (defaults differ for services vs jobs).

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| `MAINTENANCE POLICY` | Account object | SQL DDL | Used by consumers to control when Native App upgrades can start (preview feature). |
| `CREATE MAINTENANCE POLICY` / `ALTER MAINTENANCE POLICY` | SQL commands | SQL reference | Mechanism for setting upgrade windows. |
| SPCS service spec (`volumes[].blockConfig.snapshotOnDelete`, `snapshotDeleteAfter`) | YAML/service specification | SPCS docs / BCR | Controls snapshot-on-delete behavior + retention. |
| Workspaces Notebooks runtime | Platform feature | Release note | Powered by SPCS; exposes compute pool selection + idle time settings. |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata
- `ORG_USAGE` = Organization-level
- `INFO_SCHEMA` = Database-level

## MVP Features Unlocked

1. **Consumer upgrade-window awareness for our Native App:**
   - Detect/guide consumers to set a maintenance policy before enabling auto-upgrades.
   - Add an “Upgrade window / maintenance policy” section in the app UI + docs.
2. **SPCS cleanup cost guardrail:**
   - Add a pre-flight checklist/recommendation when users run “stop compute pool” / “drop service” flows: explain snapshot billing + how to opt out (`snapshotOnDelete: false`) when appropriate.
3. **Notebook cost hygiene playbook:**
   - Since Workspaces Notebooks are SPCS-backed, add a FinOps rule pack: idle-time enforcement, GPU pool governance, and EAI hygiene (who can enable outbound access) with suggested policies.

## Concrete Artifacts

### UI copy / runbook snippet: Native App upgrade windows

- If you’re using provider-driven upgrades (release directive), set a maintenance policy to avoid upgrades during business hours.
- Provide a one-liner SQL example (consumer-side):

```sql
-- Pseudocode (confirm exact syntax in SQL reference before publishing)
-- CREATE MAINTENANCE POLICY <name> ...
-- ALTER MAINTENANCE POLICY <name> SET ...
```

### SPCS service-spec checklist for block volumes

```yaml
# Relevant excerpt for services using block volumes
volumes:
  - name: <vol>
    source: block
    size: <bytes>
    blockConfig:
      snapshotOnDelete: false      # opt out (default true for services)
      snapshotDeleteAfter: 7d      # default is 7 days when enabled
```

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Exact SQL syntax for maintenance policy schedules isn’t included in the release note excerpt. | Could publish incorrect examples in docs/UI. | Pull the SQL reference pages for `CREATE/ALTER MAINTENANCE POLICY` and confirm parameters. |
| Behavior change bundle 2026_01 is **pending** and may not be enabled for all accounts yet. | Recommendations might be premature for some customers. | Track bundle status + confirm in docs “bundle history” before alerting aggressively. |
| Notebook cost-management features may surface differently by region/account edition. | FinOps rules might not apply uniformly. | Validate in a test account + check Workspaces/Notebooks docs for edition/region constraints. |

## Links & Citations

1. Consumer-controlled maintenance policies for Native Apps (Preview) — Jan 23, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
2. Notebooks in Workspaces (GA) — Feb 05, 2026: https://docs.snowflake.com/en/release-notes/2026/other/2026-02-05-notebooks-in-workspaces
3. SPCS behavior change (2026_01 bundle) — Ref 2206: https://docs.snowflake.com/en/release-notes/bcr-bundles/2026_01/bcr-2206

## Next Steps / Follow-ups

- Fetch + confirm SQL syntax for `CREATE/ALTER MAINTENANCE POLICY`, then add a small “Upgrade control” doc section to our Native App.
- Add a FinOps detection rule idea: flag SPCS services with block volumes where `snapshotOnDelete` is enabled + volumes are large; estimate snapshot retention cost.
- Decide whether Notebooks in Workspaces should be treated as a first-class workload category in our cost model (separate chargeback tags / dashboards).
