# Deep research — Snowflake FinOps Native App using Parallel APIs (metering + cost visibility + RLS + SPCS)

Date: 2026-02-22  
Focus: designing a FinOps Snowflake Native App that (a) monetizes via Marketplace, (b) provides cost visibility to consumers, (c) securely shares cost data using row-level controls, and (d) addresses Snowpark Container Services (SPCS) cost drivers.

---

## Executive summary (what matters for the app)

1. **Marketplace monetization for Native Apps is primarily configured at listing level, but metering is emitted in-app.**
   * For usage-based plans, providers can combine: **billable events**, **per-query charge**, and **monthly fee**; subscription plans are billed upfront. Billable events (Custom Event Billing) are only available for listings that share an **application** (not data-only listings).  
   Source: Snowflake “Paid listings pricing models” doc. https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model

2. **Custom Event Billing is implemented with Snowflake system functions callable only from within an installed app in the consumer account.**
   * Providers add stored procedures in the app setup script that call **`SYSTEM$CREATE_BILLING_EVENT`** (single) or **`SYSTEM$CREATE_BILLING_EVENTS`** (batch). Snowflake explicitly does **not** support alternative metering approaches (e.g., reading a table/UDF of consumer activity or telemetry from event tables) as the base for billing events.  
   Source: “Add billable events to an application package”. https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

3. **Consumer “cost visibility” features should blend (a) what Snowflake already provides in Snowsight cost management and (b) app-provided attribution views.**
   * Snowsight provides org-level and account-level cost dashboards and drilldowns, with 72h latency; deeper analysis is via **`ACCOUNT_USAGE`** and **`ORGANIZATION_USAGE`** views.  
   Source: “Exploring overall cost”. https://docs.snowflake.com/en/user-guide/cost-exploring-overall

4. **Row-level access controls for cost data sharing should rely on secure views + row access policies; cross-account sharing requires careful use of context functions and/or shared database roles.**
   * Snowflake row-level security is implemented via **row access policies**; at runtime Snowflake evaluates policies using the policy owner role and builds a dynamic secure view.  
   Source: “Understanding row access policies”. https://docs.snowflake.com/en/user-guide/security-row-intro
   * For **data sharing**, policies that depend on `CURRENT_ROLE` / `CURRENT_USER` may return `NULL` in the consumer context; Snowflake advises using `CURRENT_ACCOUNT` or database-role-based approaches (e.g., `IS_DATABASE_ROLE_IN_SESSION` + sharing a database role).  
   Sources:
     * Row access policy doc (data sharing notes). https://docs.snowflake.com/en/user-guide/security-row-intro
     * “Share data protected by a policy”. https://docs.snowflake.com/en/user-guide/data-sharing-policy-protected-data
   * For **secure views**, Snowflake explains non-secure view optimizations can indirectly expose data; secure views prevent certain inference/exfil patterns and hide view definition from unauthorized users.  
   Source: “Working with Secure Views”. https://docs.snowflake.com/en/user-guide/views-secure

5. **SPCS (compute pools) is an especially important cost surface area for FinOps apps; both consumer + provider incur costs.**
   * Consumer infra costs include compute pools, warehouse compute, storage, and data transfer; compute pool charges appear separately; no costs when compute pool is **suspended**.  
   Source: “Costs associated with apps with containers”. https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance
   * SPCS costs break down into **storage**, **compute pool**, **data transfer**. Compute pools are billed when in **IDLE/ACTIVE/STOPPING/RESIZING**, not when **STARTING/SUSPENDED**; **AUTO_SUSPEND** is recommended.  
   Source: “Snowpark Container Services costs”. https://docs.snowflake.com/en/developer-guide/snowpark-container-services/accounts-orgs-usage-views

---

## 1) Native App monetization + metering APIs (Custom Event Billing)

### 1.1 Monetization models for Marketplace listings

Snowflake Marketplace listing pricing models (provider perspective):

* **Usage-based** (billed in arrears in months where usage occurs)
  * Charge components can be combined:
    * **Billable events** (Custom Event Billing) — only for listings that share an *application*
    * **Per-query charge** — fixed price per query referencing the shared content
    * **Monthly fee** — fixed price per calendar month with at least one usage event
* **Subscription-based** (billed upfront)
  * Recurring or non-recurring, for a specified term

Notable mechanics that impact a FinOps Native App:

* **Custom Event Billing requires configuration in both places**:
  * In the app package: emit billable events (via system functions)
  * In Provider Studio: declare the billable event classes and billing quantities in the listing
* **Providers are paid via Stripe** for cash payments; Snowflake pays providers for capacity drawdown purchases.

Source: https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model

### 1.2 Emitting billable events from inside the app

Snowflake’s “Custom Event Billing” model is strongly constrained by design:

* Billable events are emitted **only by calling system functions** inside stored procedures:
  * `SYSTEM$CREATE_BILLING_EVENT(...)`
  * `SYSTEM$CREATE_BILLING_EVENTS('<json_array_of_events>')`
* These functions can be called **only from a Snowflake Native App installed in a consumer account**.
* Snowflake explicitly **does not support** deriving billing via:
  * querying a table or UDF that outputs consumer activity
  * using telemetry logged in an event table as the basis for billing

Implication: keep your metering logic **simple, deterministic, and locally derivable** within the same stored procedure that performs the billed action.

Source: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

### 1.3 Practical metering design patterns for FinOps apps

For a FinOps-oriented Native App, the “value” you monetize might be:

* number of assets analyzed (warehouses, databases, SPCS services)
* number of recommendations produced
* number of anomalies detected
* number of alerts delivered
* volume of rows scanned by your optimization routines

However, because Snowflake discourages using telemetry outputs as a billing basis, align billing events to **explicit user-triggered actions**.

Recommended patterns:

1. **Bill “per analysis run”**: emit `ANALYSIS_RUN` on demand when consumer triggers a run.
2. **Bill “per alert delivered”**: emit `ALERT_SENT` when app sends a notification through a Snowflake native mechanism.
3. **Bill “per object assessed”**: in the same procedure that iterates targets, count them and emit a billing event with base charge = count * quantity.
4. **Batch billing for performance & limits**: use `SYSTEM$CREATE_BILLING_EVENTS` to emit a batch of up to your operational granularity; Snowflake notes batching reduces likelihood of exceeding call limits.

Source (batching guidance): https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

### 1.4 Validating the consumer billing experience

Snowflake provides a consumer-side validation approach:

* Query the view `SNOWFLAKE.DATA_SHARING_USAGE.MARKETPLACE_PAID_USAGE_DAILY` and filter to `charge_type = 'MONETIZABLE_BILLING_EVENTS'`.

This is important for your app QA harness: include a scripted validation step in a consumer test account after waiting for view latency.

Source: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

---

## 2) Cost visibility features for app consumers (product requirements + data sources)

### 2.1 What Snowflake already provides in Snowsight

Snowsight offers cost dashboards that can be used as baseline expectations for “native” consumer experience:

* **Organization Overview**
  * contract remaining balance, accumulated spend, monthly spend, and per-account spend summary
* **Account Overview**
  * entry point for account-level spend optimization; tiles can show top warehouses by cost, etc.
* **Consumption**
  * drill down by day/week/month and by usage type (compute/storage/data transfer)

Operational realities:

* Data latency: **up to 72 hours**
* Times are displayed in **UTC**

Source: https://docs.snowflake.com/en/user-guide/cost-exploring-overall

### 2.2 What a FinOps Native App should add on top

Your app differentiators can be:

1. **Attribution views not provided out-of-the-box**
   * Map spend to: application features, business units, product teams, environments, tenant/customer, etc.
2. **Near-real-time signals**
   * Snowsight lags; your app can stream operational signals into consumer tables (within policy constraints).
3. **Actionability**
   * Link “what cost” → “why” → “what to do next” with recommended configuration changes.
4. **SPCS and serverless surfaces**
   * Many teams struggle to attribute SPCS compute pools and internal data transfer.

### 2.3 Data sources to power consumer cost dashboards (without over-privileging)

Snowflake endorses two core schemas for cost/usage:

* `SNOWFLAKE.ACCOUNT_USAGE` (single account)
* `SNOWFLAKE.ORGANIZATION_USAGE` (multi-account)

Example query for org-wide total usage in currency (by account) is explicitly provided:

```sql
SELECT
  account_name,
  ROUND(SUM(usage_in_currency), 2) AS usage_in_currency
FROM snowflake.organization_usage.usage_in_currency_daily
WHERE usage_date > DATEADD(month, -1, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 2 DESC;
```

Source: https://docs.snowflake.com/en/user-guide/cost-exploring-overall

App product implication: build a **data access tier** that can run under a minimal role but still query these views; for cross-account views, you may need ORGADMIN or separate admin flows.

---

## 3) Row-level access controls for cost data sharing (RLS + secure views + cross-account sharing)

This section is about **sharing cost data safely** across tenants/teams/accounts while minimizing data leakage.

### 3.1 Row access policies (row-level security) — key behaviors

Snowflake implements row-level security by attaching **row access policies** to tables or views.

Key semantics:

* A row access policy is a **schema-level object** returning BOOLEAN.
* It can be simple (role checks) or reference a **mapping table**.
* At runtime Snowflake:
  1. detects the policy attachment
  2. creates a **dynamic secure view** of the object
  3. binds column values into policy parameters and evaluates
  4. returns only rows where policy expression evaluates to `TRUE`
* **Evaluation is done using the policy owner role**, not the query operator role, which helps avoid requiring consumers to have direct access to mapping tables.

Source: https://docs.snowflake.com/en/user-guide/security-row-intro

Performance / design guidance in the docs:

* Limit policy arguments (Snowflake may need to scan bound columns even if not referenced)
* Prefer simpler expressions; mapping table lookups can reduce performance
* For very large tables, clustering by policy filtering attributes can improve performance

Source: https://docs.snowflake.com/en/user-guide/security-row-intro

### 3.2 Secure views — why they matter for cost data

Snowflake highlights risks of non-secure views:

* internal optimizations can indirectly expose hidden data through user code/UDFs
* view definitions are visible by default

Secure views:

* avoid those optimizations, reducing risk of inference/exposure
* hide definitions except to authorized roles

Trade-off: secure views can be slower.

Source: https://docs.snowflake.com/en/user-guide/views-secure

For a FinOps app: **publish cost-sharing interfaces as SECURE VIEWs**, especially when your app must enforce tenant isolation.

### 3.3 Cross-account sharing: context functions and database roles

When policy-protected data is shared:

* If a provider’s policy conditions call `CURRENT_ROLE` / `CURRENT_USER` (or a secure UDF), Snowflake returns `NULL` for these in the consumer account; workaround is to use `CURRENT_ACCOUNT`.
* Alternative recommended approach: use `IS_DATABASE_ROLE_IN_SESSION` and **share the database role**.

Sources:

* Row access policies data sharing notes: https://docs.snowflake.com/en/user-guide/security-row-intro
* Detailed workflow for sharing policy-protected data via shared database role: https://docs.snowflake.com/en/user-guide/data-sharing-policy-protected-data

The “Share data protected by a policy” doc also clarifies:

* Consumer must **activate the mounted database** to make the shared database role active in session (`USE DATABASE mounted_db`), or use fully-qualified names.
* The provider must create the database role in the **same database as the protected table** (when policies and tables are in different DBs).

Source: https://docs.snowflake.com/en/user-guide/data-sharing-policy-protected-data

### 3.4 Recommended pattern for multi-tenant cost sharing

For a FinOps Native App aiming to support multi-tenant / multi-team cost attribution:

* Store cost facts in a single table with columns like `tenant_id`, `consumer_account`, `workload_id`, etc.
* Expose **SECURE VIEWs** for consumption
* Apply a **row access policy** to those views/tables:
  * For in-account separation: use `CURRENT_ROLE()` mapping
  * For cross-account sharing: use `CURRENT_ACCOUNT()` or shared database roles

Important: Snowflake documents that a row access policy on shared objects has limitations; consumers cannot apply policies to shared tables/views and may need to create local views.

Source: https://docs.snowflake.com/en/user-guide/security-row-intro

---

## 4) Snowpark Container Service (SPCS) costs + optimization guidance for the app

### 4.1 Cost model for Native Apps with containers

Snowflake splits costs into:

* **Costs determined by the provider** (Marketplace pricing plan)
* **Infrastructure costs** borne by consumer:
  * compute pools
  * warehouse compute
  * storage
  * data transfer

Consumer controls:

* consumers can view compute pools using `SHOW COMPUTE POOLS IN ACCOUNT`
* costs are not incurred when a compute pool is **suspended**

Provider costs:

* provider pays for compute pools used during dev/test/support
* provider pays storage for versioned container images copied into an image repository stage; this repository isn’t directly accessible/observable by provider or consumer

Source: https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance

### 4.2 SPCS platform costs (storage + compute pool + transfer)

Snowflake SPCS costs:

1. **Storage**
   * image repository uses a Snowflake stage → stage storage costs apply
   * event tables for logs → table storage costs apply
   * mounting stages as volumes → stage storage costs
   * mounting compute pool node storage as volume → no extra cost beyond node
   * block storage volumes and snapshots billed per the Service Consumption Table

2. **Compute pool**
   * billed based on number/type of VM nodes (instance family)
   * charges accrue when pool is in **IDLE, ACTIVE, STOPPING, RESIZING**
   * no charges when **STARTING or SUSPENDED**
   * use **AUTO_SUSPEND** to optimize
   * monitor via `SNOWPARK_CONTAINER_SERVICES_HISTORY` and `METERING_*_HISTORY` views filtered to `service_type = SNOWPARK_CONTAINER_SERVICES`

3. **Data transfer**
   * outbound transfer billed at standard Snowflake rates; can query `DATA_TRANSFER_HISTORY` where `transfer_type = SNOWPARK_CONTAINER_SERVICES`
   * internal data transfer between compute entities is separately tracked (`INTERNAL_DATA_TRANSFER_HISTORY`, `transfer_type = INTERNAL`)
   * note: data transfer costs not currently billed for accounts on GCP

Source: https://docs.snowflake.com/en/developer-guide/snowpark-container-services/accounts-orgs-usage-views

### 4.3 App-level optimization features to implement

If your FinOps app runs in SPCS, you should include features that help consumers reduce “infra spend”:

* **Compute pool lifecycle automation**
  * suggest AUTO_SUSPEND settings
  * surface pools stuck in IDLE
  * recommend min/max node bounds

* **Cost attribution for compute pools**
  * present hourly consumption from `SNOWPARK_CONTAINER_SERVICES_HISTORY`
  * join to your app-level workload metadata to show “why pool was up”

* **Data transfer and internal transfer guardrails**
  * show `DATA_TRANSFER_HISTORY` and `INTERNAL_DATA_TRANSFER_HISTORY` as first-class cost drivers

* **Logging retention controls**
  * if you store logs in event tables, provide retention / purge tooling to avoid storage bloat

---

## Concrete artifact: SQL draft — minimal FinOps Native App schema + RLS/secure view + billing events pattern

This artifact is a **draft** intended for design discussion. It combines:

* a metering event catalog (for mapping billing classes to semantic app actions)
* consumer-facing cost fact tables (attribution)
* RLS patterns for multi-tenant sharing

### A) App-owned schema objects (provider writes, consumer queries)

```sql
-- 1) Core schemas
CREATE SCHEMA IF NOT EXISTS FINOPS_APP;
CREATE SCHEMA IF NOT EXISTS FINOPS_APP_SECURE;

-- 2) Catalog of billable event classes that the listing will declare
--    (Keep aligned with Provider Studio configuration requirements)
CREATE TABLE IF NOT EXISTS FINOPS_APP.BILLABLE_EVENT_CATALOG (
  event_class              STRING NOT NULL,   -- e.g. 'ANALYSIS_RUN'
  event_subclass           STRING,            -- provider-only dimension
  unit_name                STRING,            -- e.g. 'run', 'asset', 'alert'
  billing_quantity_usd     NUMBER(10,4) NOT NULL, -- $ per unit used to compute base_charge
  description              STRING,
  is_active                BOOLEAN DEFAULT TRUE,
  created_at               TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 3) App-internal run log (NOT used as billing source of truth, but for attribution / UX)
CREATE TABLE IF NOT EXISTS FINOPS_APP.APP_RUN_LOG (
  run_id                   STRING,
  run_ts                   TIMESTAMP_LTZ,
  run_type                 STRING,     -- e.g. 'WAREHOUSE_RIGHTSIZING'
  requested_by_user        STRING,
  requested_by_role        STRING,
  tenant_id                STRING,
  status                   STRING,
  details                  VARIANT
);

-- 4) Cost facts (example: daily attribution results)
CREATE TABLE IF NOT EXISTS FINOPS_APP.COST_FACT_DAILY (
  usage_date               DATE,
  tenant_id                STRING,
  cost_category            STRING,     -- 'WAREHOUSE', 'SERVERLESS', 'SPCS', 'TRANSFER', etc.
  object_type              STRING,
  object_name              STRING,
  credits                  NUMBER(38,6),
  usage_in_currency        NUMBER(38,6),
  source_view              STRING,     -- e.g. 'ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY'
  computed_at              TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  attrs                    VARIANT
);

-- 5) Entitlements mapping table for in-account RLS
CREATE TABLE IF NOT EXISTS FINOPS_APP.TENANT_ROLE_ENTITLEMENTS (
  tenant_id                STRING,
  role_name                STRING
);
```

### B) Row access policy + secure view for tenant isolation (in-account)

This is aligned to Snowflake’s secure view guidance and row access policy model.

```sql
-- Secure view that consumers use
CREATE OR REPLACE SECURE VIEW FINOPS_APP_SECURE.COST_FACT_DAILY_V
AS
SELECT * FROM FINOPS_APP.COST_FACT_DAILY;

-- Row access policy: allow viewing rows only if current_role is entitled to that tenant
CREATE OR REPLACE ROW ACCESS POLICY FINOPS_APP.TENANT_RLS
AS (tenant_id STRING)
RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1
    FROM FINOPS_APP.TENANT_ROLE_ENTITLEMENTS e
    WHERE UPPER(e.role_name) = CURRENT_ROLE()
      AND e.tenant_id = tenant_id
  );

-- Attach policy to the secure view
ALTER VIEW FINOPS_APP_SECURE.COST_FACT_DAILY_V
  ADD ROW ACCESS POLICY FINOPS_APP.TENANT_RLS ON (tenant_id);
```

Notes:

* For **cross-account sharing**, you likely need `CURRENT_ACCOUNT()` or shared database roles (`IS_DATABASE_ROLE_IN_SESSION`) rather than `CURRENT_ROLE()` / `CURRENT_USER()` due to NULL behavior in consumer accounts for shared objects.  
  Sources: https://docs.snowflake.com/en/user-guide/security-row-intro and https://docs.snowflake.com/en/user-guide/data-sharing-policy-protected-data

### C) Pseudocode pattern for emitting billable events from procedures

From Snowflake docs, billable events must be created by calling system functions inside app procedures; a simplified pattern:

```sql
-- (Pseudo) procedure skeleton: do work, compute units, then emit billing event
-- Implementation language may be JavaScript/Python/Java per docs.
-- Call SYSTEM$CREATE_BILLING_EVENT or SYSTEM$CREATE_BILLING_EVENTS.

-- Example is conceptual; actual implementation follows Snowflake Native App packaging guidance.
```

Doc reference: https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

---

## Design implications / ADR candidates (short list)

1. **ADR: Billing strategy**
   * Choose 1–3 billable event classes max (avoid pricing confusion)
   * Prefer action-based billing units; avoid telemetry-derived billing signals
   * Batch events where possible

2. **ADR: Consumer cost visibility architecture**
   * Use Snowflake `ACCOUNT_USAGE` + your app’s derived attribution tables
   * Accept 72h latency in Snowsight; add “recent activity” UX via app logs

3. **ADR: Multi-tenant RLS strategy**
   * In-account: `CURRENT_ROLE` mapping table
   * Cross-account: `CURRENT_ACCOUNT` or shared database role model
   * Ensure all consumer-facing objects are secure views

4. **ADR: SPCS cost control**
   * Default to aggressive compute pool auto-suspend; expose recommendations
   * Treat internal data transfer as a first-class cost metric

---

## Source URLs (cited)

* Paid listings pricing models (Marketplace monetization + Custom Event Billing config):
  https://docs.snowflake.com/en/collaboration/provider-listings-pricing-model

* Add billable events to an application package (Custom Event Billing implementation + constraints + validation view):
  https://docs.snowflake.com/en/developer-guide/native-apps/adding-custom-event-billing

* Exploring overall cost (Snowsight cost management UI + usage views):
  https://docs.snowflake.com/en/user-guide/cost-exploring-overall

* Understanding row access policies (row-level security semantics + data sharing caveats):
  https://docs.snowflake.com/en/user-guide/security-row-intro

* Share data protected by a policy (shared database roles + IS_DATABASE_ROLE_IN_SESSION workflow):
  https://docs.snowflake.com/en/user-guide/data-sharing-policy-protected-data

* Working with Secure Views (why secure views matter + trade-offs):
  https://docs.snowflake.com/en/user-guide/views-secure

* Costs associated with apps with containers (native app + containers: consumer vs provider costs):
  https://docs.snowflake.com/en/developer-guide/native-apps/container-cost-governance

* Snowpark Container Services costs (storage/compute/data transfer + monitoring views + auto-suspend):
  https://docs.snowflake.com/en/developer-guide/snowpark-container-services/accounts-orgs-usage-views
