# Native Apps Research Note — Consumer-controlled maintenance policies (Preview)

- **When (UTC):** 2026-02-02 10:59
- **Scope:** Native App Framework (consumer operations / upgrade control)

## Accurate takeaways
- Snowflake added **consumer-controlled maintenance policies** for **Snowflake Native Apps** in **public preview** (release note dated **Jan 23, 2026**).
- A consumer can **delay an app upgrade** so it **doesn’t start during restricted periods**. The upgrade still begins when the provider sets a new release directive, but it can be **deferred until the policy start time**.
- Policies are expressed as a **CRON schedule** (start time only).
- A consumer can apply a maintenance policy:
  - **account-wide for all apps** (`ALTER ACCOUNT … FOR ALL APPLICATIONS`)
  - **per-app** (`ALTER APPLICATION …`)
- Constraints called out by Snowflake:
  - Only **start time** can be specified (no end time/duration).
  - Each **account/app can only have one** policy set.
  - Provider can set a **maintenance deadline** to prevent indefinite postponement.

## Packaging / permissions implications
- This is consumer-side behavior; providers don’t need to change packaging to enable it, but providers should expect upgrades can be **delayed**.
- Consumer privileges:
  - `CREATE MAINTENANCE POLICY` on **schema** (to create the policy)
  - `APPLY MAINTENANCE POLICY` on **account** (to apply to account/app)
  - `APPLY` or `OWNERSHIP` on the **maintenance policy** (to apply/view)

## MVP features unlocked (PR-sized)
1) **“Upgrade readiness / maintenance policy” check** in Mission Control: detect whether the account has a maintenance policy applied for apps (and surface recommended safe window).
2) **Provider-side release guidance copy**: add an “Operational readiness” section in our app docs/UI explaining how consumers can schedule upgrades + what to test during that window.
3) **Alerting heuristic**: if consumers heavily defer upgrades (policy start far out) and provider sets a deadline, warn about potential “forced upgrade” risk window.

## Risks / assumptions
- Preview behavior may change (syntax, semantics, deadline rules).
- We need to confirm what telemetry (if any) is exposed to providers about consumer maintenance policies (likely limited).
- The doc references a “Maintenance window” section under Snowpark Container Services compute pool docs; unclear if any shared behavior exists beyond the conceptual “maintenance window.”

## Links / references
- Release note (Jan 23, 2026): https://docs.snowflake.com/en/release-notes/2026/other/2026-01-23-native-apps-consumer-maintenance-policies
- Consumer maintenance policies doc: https://docs.snowflake.com/en/developer-guide/native-apps/consumer-maintenance-policies
- SQL: CREATE MAINTENANCE POLICY: https://docs.snowflake.com/en/sql-reference/sql/create-maintenance-policy
- SQL: ALTER ACCOUNT: https://docs.snowflake.com/en/sql-reference/sql/alter-account
- SQL: ALTER APPLICATION: https://docs.snowflake.com/en/sql-reference/sql/alter-application
