# PR1 Contract — Idle Cost Report (Daily, Credits-only)

## Goal
Provide a **high-signal daily idle waste surface** for Snowflake warehouses that is:
- easy to validate from Snowflake-native sources
- stable enough to drive deterministic recommendations
- deliberately **credits-only** (no $ mapping in PR1)

## Data Source
- `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`
  - expected latency: ~3 hours
  - retention: long (account usage)

## Canonical Definitions
- **Total compute credits**: `SUM(CREDITS_USED_COMPUTE)`
- **Query-attributed compute credits**: `SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)`
- **Idle compute credits**: `total_compute_credits - query_attributed_compute_credits`
- **Idle %**: `100 * idle_compute_credits / total_compute_credits`

> Notes:
> - This focuses on *compute* waste. Cloud services are excluded for PR1.
> - We exclude the current day to avoid partial-day skew.

## Views
### 1) `V_WAREHOUSE_IDLE_CREDITS_DAILY`
**Grain:** `warehouse_name, usage_date`

**Columns**
- `WAREHOUSE_NAME` (STRING)
- `USAGE_DATE` (DATE)
- `TOTAL_COMPUTE_CREDITS` (NUMBER)
- `QUERY_ATTRIBUTED_COMPUTE_CREDITS` (NUMBER)
- `IDLE_COMPUTE_CREDITS` (NUMBER)
- `IDLE_PCT` (NUMBER(5,2))

**Default lookback:** last 60 days

### 2) `V_WAREHOUSE_IDLE_TOP_OFFENDERS_7D`
**Grain:** `warehouse_name`

**Columns**
- `WAREHOUSE_NAME`
- `TOTAL_COMPUTE_CREDITS_7D`
- `QUERY_ATTRIBUTED_COMPUTE_CREDITS_7D`
- `IDLE_COMPUTE_CREDITS_7D`
- `IDLE_PCT_7D`
- `IDLE_CREDITS_RANK_7D`

## Recommendation Card (Deterministic)
**Card name:** `Idle Warehouse Spend`

### Trigger
- Warehouse has meaningful spend and waste:
  - `TOTAL_COMPUTE_CREDITS_7D > 10` (tunable)
  - `IDLE_PCT_7D >= 20` (tunable)

### Copy / Output fields
- headline: `High idle compute detected`
- evidence:
  - `idle_pct_7d`
  - `idle_compute_credits_7d`
  - `total_compute_credits_7d`
- action:
  - `Review AUTO_SUSPEND / AUTO_RESUME settings`

### Non-goals (PR1)
- No automatic ALTER WAREHOUSE actions
- No $ conversion
- No hour-level bucketing / timezone handling

## Open Questions (deferred)
- Incorporate `WAREHOUSE_EVENTS_HISTORY` to detect whether `AUTO_SUSPEND` is effectively disabled / very high.
- Add segmentation by warehouse size / type.
- Add cloud services credits and comprehensive spend reconciliation.
