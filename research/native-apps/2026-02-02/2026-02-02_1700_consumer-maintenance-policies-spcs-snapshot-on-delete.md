# Native Apps Research Note — Consumer-controlled maintenance policies (Preview) + SPCS snapshot-on-delete billing change

- **When (UTC):** 2026-02-02 17:00
- **Scope:** Native App Framework (+ adjacent Snowpark Container Services behavior change)

## Accurate takeaways
- Snowflake added **consumer-controlled maintenance policies** for **Snowflake Native Apps** in **public preview** (release note dated **2026-01-23**).
- Consumers can define a **maintenance policy** that **delays Native App upgrades** until a specified **start date/time** (i.e., to avoid upgrades during blackout periods).
- Consumers manage this via SQL:
  - `CREATE MAINTENANCE POLICY` (defines schedule, e.g., CRON)
  - `ALTER MAINTENANCE POLICY`, plus applying policies with:
    - `ALTER ACCOUNT ... FOR ALL APPLICATIONS`
    - `ALTER APPLICATION ...`
  - discovery/inspection via `SHOW MAINTENANCE POLICIES`, `DESCRIBE MAINTENANCE POLICY`
- Constraints called out in docs:
  - Only a **start time** is specified (no explicit end time/duration).
  - **One** maintenance policy per app/account.
  - Providers can set a **maintenance deadline** for an upgrade (consumer can’t postpone indefinitely).
- Adjacent infra change (behavior change bundle **2026_01**, ref **2206**, status **Pending**): for **Snowpark Container Services block volumes**, when you delete a volume via certain operations, Snowflake will **create snapshots** and retain them for **7 days by default**, and **you are billed** for these snapshots.
  - Affects `DROP SERVICE ... FORCE`, `ALTER COMPUTE POOL ... STOP ALL`, and `ALTER SERVICE ... RESTORE VOLUME FROM SNAPSHOT`.
  - You can opt out per service with `snapshotOnDelete: false` and control retention with `snapshotDeleteAfter`.

## Packaging / permissions implications
- As an app provider, we should assume **upgrades may be delayed** by consumer policy; app-side guidance should:
  - communicate expected upgrade behavior, deadlines, and testing windows
  - recommend a “safe” weekly maintenance schedule in UTC
- If our app uses SPCS and block volumes, the snapshot-on-delete change introduces **cost + retention** implications:
  - We should consider explicitly setting `snapshotOnDelete` / `snapshotDeleteAfter` in service specs to avoid surprise bills.

## MVP features unlocked (PR-sized)
1) **In-app “Upgrade readiness & scheduling” panel**: explain consumer-controlled maintenance policies, with copy-pastable SQL snippets (`CREATE MAINTENANCE POLICY ...`, `ALTER APPLICATION ... SET MAINTENANCE POLICY ...`).
2) **Pre-upgrade checklist**: add a “recommended maintenance window” (UTC) and warn that upgrades may be forced by provider deadline.
3) **SPCS cost guardrail** (if we run SPCS): ensure our service specs explicitly set `snapshotOnDelete` and `snapshotDeleteAfter`, and document expected snapshot costs.

## Risks / assumptions
- Preview behavior may change (syntax, semantics, UI surfacing) before GA.
- It’s unclear what visibility a provider app has into a consumer’s current maintenance policy from inside the app runtime; assume we may need to rely on consumer-run SQL/verification.
- The SPCS behavior-change bundle is marked **Pending**; timing/rollout may vary.

## Links / references
- Release note: Consumer-controlled maintenance policies for Native Apps (Preview) (2026-01-23): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
- Docs: Consumer-controlled maintenance policies: https://docs.snowflake.com/en/developer-guide/native-apps/consumer-maintenance-policies
- Behavior change bundle 2026_01 (ref 2206): SPCS snapshot-on-delete billed retention: https://docs.snowflake.com/en/release-notes/bcr-bundles/2026_01/bcr-2206
