# Native Apps Research Note — Consumer-controlled maintenance policies (Preview)

- **When (UTC):** 2026-02-01 22:57
- **Scope:** Native App Framework (upgrade/maintenance UX)

## Accurate takeaways
- Snowflake introduced **consumer-controlled maintenance policies** (public preview) for **Snowflake Native Apps** (release note dated **Jan 23, 2026**).
- Consumers can **set a maintenance policy that blocks app upgrades during specified time periods**.
- When a new version is available and a provider sets a **new release directive**, the upgrade would normally begin; **if a maintenance policy is set, the upgrade is delayed until the policy’s start date/time**.
- The consumer configures this with SQL:
  - `CREATE MAINTENANCE POLICY` (create a schedule window)
  - `ALTER MAINTENANCE POLICY` (apply/remove)

## Packaging / permissions implications
- This is **consumer-side control** over *when* upgrades apply; providers should assume upgrades may not happen immediately after setting a new release directive.
- Apps that rely on “upgrade happens quickly” (e.g., for security fixes, schema migrations, or feature flags) should:
  - design for **version skew** across consumers,
  - keep migrations **backward compatible** for longer,
  - communicate **recommended maintenance windows** and timelines.

## MVP features unlocked (PR-sized)
1) **In-app upgrade readiness banner + playbook**: add a UI section explaining the maintenance policy feature and the exact SQL commands to set an “allowed upgrade window” (aimed at admins).
2) **Provider release checklist update**: document operational expectations for version skew + guidance for scheduling upgrades (include example policies for “business hours only” vs “off-hours”).
3) **Telemetry/health check**: if the app can detect it’s behind latest (or detect upgrade directive vs current version), surface a warning that a maintenance policy may be delaying upgrades and link to the docs.

## Risks / assumptions
- Feature is **Preview**; behavior, permissions, and UI surfaces may change before GA.
- Assumption: consumers have sufficient privileges to create/alter maintenance policies in their account; exact RBAC requirements need validation.

## Links / references
- Release note: https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
- Doc: https://docs.snowflake.com/en/developer-guide/native-apps/consumer-maintenance-policies
- SQL reference:
  - https://docs.snowflake.com/en/sql-reference/sql/create-maintenance-policy
  - https://docs.snowflake.com/en/sql-reference/sql/alter-maintenance-policy
