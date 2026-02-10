# Research: FinOps - 2026-02-10
**Time:** 14:00 UTC | **Topic:** FinOps Observability & Performance Intelligence Updates  
**Researcher:** Snow (AI Assistant)

---

## Accurate Takeaways

1. **Listing & Share Observability is now GA (Feb 02, 2026)** — New ACCOUNT_USAGE views enable comprehensive cost and usage tracking for data sharing: LISTINGS, SHARES, GRANTS_TO_SHARES, plus updates to ACCESS_HISTORY capturing DDL operations on listings/shares.

2. **Owner's Rights Expansion (Feb 02, 2026)** — Native Apps can now use INFORMATION_SCHEMA views and most SHOW/DESCRIBE commands. Query history functions remain restricted (QUERY_HISTORY, LOGIN_HISTORY).

3. **Performance Explorer Enhancements (Feb 09, 2026, Preview)** — New NLP-based natural language query interface, adaptive baselines for cost anomaly detection, and enhanced visualization for resource consumption patterns.

4. **ORGANIZATION_USAGE Premium Views (Feb 01, 2026)** — New premium views added for org-level consumption analysis (exact view names TBD from docs).

5. **Snowpark Container Services in Native Apps** — Apps with containers run on compute pools created during installation; provider query text and access history are redacted to protect IP.

---

## Snowflake Objects & Data Sources

| Object/View | Type | Source | Notes |
|-------------|------|--------|-------|
| LISTINGS | Object | ACCOUNT_USAGE (new GA) | Includes dropped listings; 2-3hr latency |
| SHARES | Object | ACCOUNT_USAGE (new GA) | Provider/consumer context |
| GRANTS_TO_SHARES | ACL | ACCOUNT_USAGE (new GA) | Historical grant/revoke tracking |
| ACCESS_HISTORY | Historical | ACCOUNT_USAGE (updated) | Now logs DDL on listings/shares |
| COMPUTE_POOLS | Object | ACCOUNT_USAGE | Container app resource tracking |
| APPLICATION_DAILY_USAGE_HISTORY | Historical | ACCOUNT_USAGE | 24hr latency; 1yr retention |
| APPLICATION_SPECIFICATIONS | Object | ACCOUNT_USAGE | Native App metadata |

**Legend:**
- `ACCOUNT_USAGE` = Account-level metadata (1yr retention, 2-3hr latency)
- `ORG_USAGE` = Organization-level (premium)
- `INFO_SCHEMA` = Real-time, no latency

---

## MVP Features Unlocked

1. **Shared Data Cost Allocation Dashboard** — Use new LISTINGS/SHARES/GRANTS_TO_SHARES views to build a Native App that attributes data transfer and compute costs to specific data sharing relationships.

2. **Anomaly Detection for Listing Consumption** — Leverage APPLICATION_DAILY_USAGE_HISTORY + COMPUTE_POOLS to detect unusual spikes in consumer usage patterns on shared datasets.

3. **Self-Service Cost Explorer for Consumers** — Build Streamlit UI using INFORMATION_SCHEMA.LISTINGS + AVAILABLE_LISTINGS table function to let consumers see their own data sharing costs in real-time.

4. **Automated Cost Alerts for Shares** — Use ACCESS_HISTORY DDL tracking on listings/shares to trigger alerts when new shares are created or modified, enabling proactive cost governance.

---

## Concrete Artifacts

### SQL: Cost Attribution for Data Sharing
```sql
-- Attribution model for data sharing costs
WITH share_usage AS (
  SELECT 
    s.share_name,
    s.account_locator,
    LISTING_NAME,
    -- Join to usage history for compute attribution
    ah.user_name,
    ah.query_tag,
    ah.credits_used_cloud_services
  FROM SNOWFLAKE.ACCOUNT_USAGE.SHARES s
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES gts 
    ON s.share_name = gts.share_name
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
    ON ah.object_name = gts.table_name
  WHERE ah.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
)
SELECT 
  share_name,
  COUNT(DISTINCT account_locator) as consumer_count,
  SUM(credits_used_cloud_services) as attributed_credits
FROM share_usage
GROUP BY share_name;
```

### SQL: Anomaly Detection Baseline for Native Apps
```sql
-- Baseline for app compute pool usage
SELECT 
  DATE(start_time) as usage_date,
  compute_pool_name,
  AVG(credits_used) as avg_daily_credits,
  STDDEV(credits_used) as stddev_daily_credits,
  -- Anomaly threshold: mean + 2*stddev
  AVG(credits_used) + (2 * STDDEV(credits_used)) as anomaly_threshold
FROM SNOWFLAKE.ACCOUNT_USAGE.COMPUTE_POOLS
WHERE start_time >= DATEADD(day, -90, CURRENT_TIMESTAMP())
GROUP BY usage_date, compute_pool_name;
```

---

## Risks / Assumptions

| Risk/Assumption | Impact | Validation |
|-----------------|--------|------------|
| ACCOUNT_USAGE latency (2-3hr) may be too slow for real-time alerting | Medium | Consider hybrid approach with INFORMATION_SCHEMA for real-time + ACCOUNT_USAGE for historical |
| Snowpark Container Services compute costs not yet granularly tracked | High | Validate COMPUTE_POOLS view schema in target account before building features |
| Owner's rights permissions vary by account configuration | Medium | Test Native App in consumer sandbox account before production deployment |
| Performance Explorer NLP features are still Preview | Low | Don't build core functionality on Preview features without fallback |

---

## Links & Citations

1. https://docs.snowflake.com/en/release-notes/2026/other/2026-02-02-listing-observability-ga — Listing/Share Observability GA announcement
2. https://docs.snowflake.com/en/release-notes/2026/10_3 — Owner's rights context expansion (10.3 release notes)
3. https://docs.snowflake.com/en/release-notes/2026/other/2026-02-09-performance-explorer-enhancements-preview — Performance Explorer Preview features
4. https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about — Native Apps with Snowpark Container Services
5. https://docs.snowflake.com/en/sql-reference/account-usage — ACCOUNT_USAGE schema reference

---

## PR-Sized Task Recommendation

**Implement: "Share Cost Attribution View"**
- Create a stored procedure that queries ACCOUNT_USAGE.SHARES + ACCOUNT_USAGE.GRANTS_TO_SHARES + ACCOUNT_USAGE.ACCESS_HISTORY
- Join with METERING_HISTORY to attribute credits to specific share consumers
- Output: Streamlit table showing cost per share per consumer over last 30 days
- Estimated effort: 1-2 days | Can ship independently

---

## Next Steps / Follow-ups

- [ ] Validate COMPUTE_POOLS schema for containerized Native App cost tracking
- [ ] Test INFORMATION_SCHEMA.SHARES real-time query performance at scale
- [ ] Review ORGANIZATION_USAGE premium views for multi-account FinOps scenarios
- [ ] Monitor Performance Explorer GA timeline for NLP integration opportunities
