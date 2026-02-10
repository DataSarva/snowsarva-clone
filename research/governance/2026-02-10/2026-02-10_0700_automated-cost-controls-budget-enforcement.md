# Governance Research Note — Automated Cost Controls & Budget Enforcement for Snowflake Native Apps

- **When (UTC):** 2026-02-10 07:00
- **Scope:** Policy-as-code guardrails, automated budget enforcement, real-time spend alerting within a Native App

---

## Accurate takeaways

1. **Native Apps operate in OWNER'S RIGHTS context**, meaning procedures run with the app's defined owner privileges, not the caller's. This creates a **privilege boundary** for enforcement actions — the app can enforce policies without requiring ACCOUNTADMIN grants on every call.

2. **Snowflake's Account Usage views (`ACCOUNT_USAGE`, `ORGANIZATION_USAGE`) provide billing-grade cost data** with 1-hour latency minimum. These are queryable via `WAREHOUSE_METERING_HISTORY`, `METERING_DAILY_HISTORY`, and `ORGANIZATION_USAGE.METERING` for multi-account rollups.

3. **Budget enforcement requires three distinct operational modes** to balance safety vs. automation:
   - **MONITOR**: Silent alerting only — accumulate violations for reporting
   - **ALERT**: Active notifications via email/webhook/SNOWFLAKE.DATA_CLOUD.MESSAGE when thresholds breach
   - **ENFORCE**: Automatic interception — block/cancel queries via `SYSTEM$CANCEL_QUERY` or resource suspension

4. **Real-time enforcement is constrained by data latency**: `ACCOUNT_USAGE` has inherent 1hr+ delay. For sub-hour enforcement, we must combine:
   - `INFORMATION_SCHEMA.WAREHOUSE_LOAD_HISTORY` (latest 14 days, near-real-time)
   - `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` (per-minute credit burn)
   - Event Table spans for application-level operation attribution

5. **Policy evaluation should be idempotent and windowed**: Design policies to evaluate against trailing windows (15m, 1h, 24h) rather than absolute counters. This allows recovery from transient failures and supports "soft limit" vs "hard limit" semantics.

6. **Native App packaging constraint**: The app has no direct access to consumer's `ACCOUNT_USAGE` unless explicitly granted via `IMPORTED PRIVILEGES` or the consumer creates a `REFERENCE` to external data. This requires a **consumer-configured integration pattern**.

---

## Data sources / audit views

| Object/View | Type | Source | Latency | Notes |
|-------------|------|--------|---------|-------|
| `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | View | ACCOUNT_USAGE | 1hr+ | Billing-grade warehouse credit consumption |
| `ACCOUNT_USAGE.METERING_DAILY_HISTORY` | View | ACCOUNT_USAGE | 1hr+ | Daily rollup across service types |
| `ORGANIZATION_USAGE.METERING` | View | ORGANIZATION_USAGE | 1hr+ | Org-level daily credits |
| `INFORMATION_SCHEMA.WAREHOUSE_LOAD_HISTORY` | Table Function | INFO_SCHEMA | ~1-5 min | Running/queued/queued_provisioning by warehouse |
| `INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY` | Table Function | INFO_SCHEMA | ~1-5 min | Per-minute credit usage |
| `SNOWFLAKE.TELEMETRY.EVENTS_VIEW` | View | EVENT_TABLE | ~1 min | App spans/logs for operation attribution |

**Legend:**
- `ACCOUNT_USAGE` = Requires `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE` or `ACCOUNT_USAGE_VIEWER` role
- `ORGANIZATION_USAGE` = Requires ORGADMIN or `ORGANIZATION_USAGE_VIEWER`
- `INFO_SCHEMA` = Accessible within database, no special privileges required

---

## MVP features unlocked (PR-sized)

### 1. Budget Policy Engine (enforcement modes)

A policy-as-code table structure + evaluator that supports:

```sql
-- Example: Define a soft budget of $1000/day for "analytics-team"
INSERT INTO CFG_BUDGET_POLICY VALUES (
  'analytics-daily',
  'analytics-team',
  'DAILY',
  1000.00,
  'ALERT',  -- MONITOR | ALERT | ENFORCE
  'ACTIVE'
);
```

The evaluator runs every 15 minutes via TASK and:
- Aggregates spend by `cost_center` / `owner_id` (from attribution mapping)
- Compares against policy thresholds
- Emits actions: log (MONITOR) → DATA_CLOUD.MESSAGE (ALERT) → SYSTEM$CANCEL_QUERY (ENFORCE)

### 2. Real-time Credit Burn Dashboard (sub-hour)

Combine `WAREHOUSE_METERING_HISTORY` (per-minute) + attribution rules to show "current spend rate" without waiting for ACCOUNT_USAGE lag. Critical for "am I about to blow my budget" UX.

### 3. Policy Violation Audit Trail

Immutable table capturing every evaluated policy, the computed spend, threshold, and action taken. Enables compliance reporting and ML training for anomaly detection.

---

## Concrete artifacts

### SQL: Budget Policy Schema + Evaluator

See: `/home/ubuntu/.openclaw/workspace/sql/cost_governance_budget_enforcement.sql`

Includes:
- `CFG_BUDGET_POLICY` — policy definitions (scope, threshold, mode, window)
- `POLICY_VIOLATION_LOG` — immutable audit of all evaluations
- `SP_EVALUATE_BUDGET_POLICIES` — idempotent evaluator procedure
- `V_REALTIME_CREDIT_BURN` — near-real-time spend rate view

---

## Risks / assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| Consumer must grant IMPORTED PRIVILEGES for account-wide enforcement | Medium | Document in setup wizard; provide "limited mode" with INFO_SCHEMA only |
| Sub-hour INFO_SCHEMA data may lag >5 minutes during high load | Low-Medium | Graceful degradation: mark data as "stale" in UI |
| SYSTEM$CANCEL_QUERY requires WAREHOUSE admin or caller must own query | High | ENFORCE mode only works for queries issued via app's proxy/procedures |
| Policy evaluation at 15-min intervals may miss burst spend | Medium | Add "rate limit" policies (credits/hour) not just "budget cap" policies |
| Query ID attribution to "owner" requires QUERY_TAG discipline | Medium | Include attribution health check in onboarding |

---

## Links / references

1. Snowflake: WAREHOUSE_METERING_HISTORY — https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history
2. Snowflake: INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY — https://docs.snowflake.com/en/sql-reference/info-schema/warehouse_metering_history
3. Snowflake: SYSTEM$CANCEL_QUERY — https://docs.snowflake.com/en/sql-reference/sql/system-cancel-query
4. Snowflake Native Apps: Owner's Rights vs. Caller’s Rights — https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-rights
5. Snowflake: IMPORTED PRIVILEGES — https://docs.snowflake.com/en/sql-reference/sql/grant-privilege#access-control-privilege-hierarchy

---

## Next steps / follow-ups

- [ ] Validate IMPORTED PRIVILEGES setup flow in test account
- [ ] Prototype `SP_EVALUATE_BUDGET_POLICIES` with actual SYSTEM$CANCEL_QUERY calls
- [ ] Design "query proxy" pattern for ENFORCE mode (app-owned SPs that wrap consumer queries)
- [ ] Evaluate row-level policy enforcement via Query History query tags
