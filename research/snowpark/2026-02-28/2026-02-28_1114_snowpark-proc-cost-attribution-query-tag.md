# Snowpark Research Note — Cost attribution for Snowpark stored procedures via QUERY_TAG + ROOT_QUERY_ID

- **When (UTC):** 2026-02-28 11:14
- **Scope:** Snowpark (Python/SQL)

## Accurate takeaways
- Snowflake’s recommended primitives for chargeback/showback are **object tags** (resources/users) + **query tags** (per-session / per-query attribution), with SQL examples that join **ACCOUNT_USAGE.TAG_REFERENCES**, **ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY**, and **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY**.  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- **ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY** provides **per-query compute credits** (credits_attributed_compute) for up to ~365 days, but:
  - may lag (docs state latency can be up to ~8 hours)
  - excludes warehouse **idle time** (idle time must be attributed separately if you want “billed credits” reconciliation)
  - excludes **short-running queries (<= ~100ms)**
  - does **not** include non-warehouse costs (cloud services, storage, serverless features, AI token costs, etc.).  
  Source: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
- For stored procedures that execute multiple statements, Snowflake documents a supported approach to compute the **total procedure compute credits** by:
  1) finding the stored procedure’s **ROOT_QUERY_ID** in **ACCOUNT_USAGE.ACCESS_HISTORY** (using parent_query_id/root_query_id columns)
  2) summing credits in **QUERY_ATTRIBUTION_HISTORY** where (root_query_id = <root> OR query_id = <root>).  
  Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- **ACCOUNT_USAGE.ACCESS_HISTORY** includes **parent_query_id** and **root_query_id** to relate nested stored procedure calls and downstream queries.  
  Source: https://docs.snowflake.com/en/user-guide/access-history

## Patterns (procs/UDFs/tasks)
- **Pattern: “Cost a stored procedure run as a tree.”**
  - Identify the user-visible stored procedure call (QUERY_HISTORY: query_type='CALL')
  - Use ACCESS_HISTORY to get the root/parent query chain
  - Aggregate QUERY_ATTRIBUTION_HISTORY by root_query_id.
- **Pattern: enforce QUERY_TAG for Snowpark workloads**
  - For Snowpark apps (or Native App services) set **QUERY_TAG** at session start (e.g., `ALTER SESSION SET QUERY_TAG='APP=<name>;TENANT=<t>;COST_CENTER=<cc>'`) so:
    - individual statements show the tag (QUERY_ATTRIBUTION_HISTORY.QUERY_TAG)
    - procedure totals can be grouped by tenant/cost center
  - This also helps with “shared application on behalf of multiple departments” scenarios described in Snowflake’s cost attribution guide.  
    Source: https://docs.snowflake.com/en/user-guide/cost-attributing
- **Pattern: idle-time reconciliation (optional)**
  - Snowflake’s canonical examples distribute idle time proportionally by usage when you need to reconcile with warehouse billed credits (WAREHOUSE_METERING_HISTORY) rather than attributed credits (QUERY_ATTRIBUTION_HISTORY).  
    Source: https://docs.snowflake.com/en/user-guide/cost-attributing
  - Practical note: external writeups flag that reconciling per-query attribution with metering can be non-trivial; validate in your target accounts and be prepared to fall back to metering-based allocation.  
    Source: https://blog.greybeam.ai/snowflake-cost-per-query/

## MVP features unlocked (PR-sized)
1) **Snowpark procedure “cost ledger” view**: compute total credits per stored procedure invocation (call) and group by QUERY_TAG (tenant/cost center).
2) **Enforced query tagging** for Snowpark execution contexts (Native App / Snowpark Python / connectors): a tiny library/helper that standardizes tag shape (APP/TENANT/COST_CENTER/ENV) + validates presence.
3) **Idle-time reconciliation toggle**: show “Attributed credits” vs “Estimated billed credits (incl idle)” for proc runs, using proportional distribution over WAREHOUSE_METERING_HISTORY.

## Concrete artifact — SQL draft (proc run cost ledger)

### A) Total attributed credits per stored procedure CALL (root_query_id rollup)
> Goal: for each procedure CALL, get a stable root_query_id and sum per-query credits underneath it.

```sql
-- Inputs
--   :start_ts, :end_ts  (TIMESTAMP_LTZ)
--   :proc_fqn_pattern   (STRING) e.g. 'MYDB.MYSCHEMA.%'

WITH proc_calls AS (
  SELECT
    qh.query_id              AS call_query_id,
    qh.start_time            AS call_start_time,
    qh.end_time              AS call_end_time,
    qh.user_name,
    qh.role_name,
    qh.warehouse_name,
    qh.query_tag,
    qh.query_text
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
  WHERE qh.query_type = 'CALL'
    AND qh.start_time >= :start_ts
    AND qh.start_time <  :end_ts
    AND qh.query_text ILIKE ('CALL ' || :proc_fqn_pattern || '%')
),
call_roots AS (
  SELECT
    pc.*,
    -- root_query_id is NULL when the CALL itself is the root; in that case use call_query_id
    COALESCE(ah.root_query_id, pc.call_query_id) AS root_query_id
  FROM proc_calls pc
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
    ON ah.query_id = pc.call_query_id
),
root_cost AS (
  SELECT
    cr.root_query_id,
    SUM(qah.credits_attributed_compute)        AS credits_attributed_compute,
    SUM(qah.credits_used_query_acceleration)  AS credits_used_query_acceleration
  FROM call_roots cr
  JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qah
    ON qah.root_query_id = cr.root_query_id
    OR qah.query_id      = cr.root_query_id
  GROUP BY cr.root_query_id
)
SELECT
  cr.call_query_id,
  cr.root_query_id,
  cr.call_start_time,
  cr.call_end_time,
  cr.user_name,
  cr.role_name,
  cr.warehouse_name,
  cr.query_tag,
  rc.credits_attributed_compute,
  rc.credits_used_query_acceleration,
  (rc.credits_attributed_compute + COALESCE(rc.credits_used_query_acceleration, 0)) AS total_query_credits
FROM call_roots cr
LEFT JOIN root_cost rc
  ON rc.root_query_id = cr.root_query_id
ORDER BY cr.call_start_time DESC;
```

### B) (Optional) Allocate warehouse idle time back to procedure runs
> Snowflake’s docs show proportional idle-time distribution patterns (by user or by query_tag). If we want “billed credits” per proc run, we can distribute *metered credits* (WAREHOUSE_METERING_HISTORY) proportional to per-proc attributed credits within the same warehouse + time bucket.

Sketch:
- bucket proc runs by `DATE_TRUNC('HOUR', call_start_time)` and `warehouse_id`
- compute `proc_attributed_credits_in_hour / total_attributed_credits_in_hour * metered_credits_in_hour`

(Left as a follow-up PR; the key is to keep both metrics visible: **attributed** vs **metered-estimated**.)

## Risks / assumptions
- **ACCESS_HISTORY gaps for failures:** ACCESS_HISTORY is not guaranteed to record every QUERY_HISTORY row; failed queries are commonly mentioned as a gap in practice. If ACCESS_HISTORY lacks a root_query_id for a CALL, you may need fallbacks (session_id + time window containment), but be careful about false positives.
- **Latency:** ACCESS_HISTORY and QUERY_ATTRIBUTION_HISTORY have non-trivial ingestion delays (hours). “Near real time” dashboards will need recent-window exclusions or an explicit “data freshness” indicator.
- **Procedure identification:** parsing procedure name from `query_text` is brittle. Prefer standardization: enforce query tagging + store proc FQN as part of the tag payload where possible.

## Links / references
- Snowflake docs — Attributing cost (tags + query tags + QUERY_ATTRIBUTION_HISTORY examples): https://docs.snowflake.com/en/user-guide/cost-attributing
- Snowflake docs — QUERY_ATTRIBUTION_HISTORY view: https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history
- Snowflake docs — Access History (parent_query_id/root_query_id): https://docs.snowflake.com/en/user-guide/access-history
- Greybeam blog — discussion of per-query attribution and idle time reconciliation: https://blog.greybeam.ai/snowflake-cost-per-query/
