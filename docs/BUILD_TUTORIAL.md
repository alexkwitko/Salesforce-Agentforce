# Kwitko Coffee — Agentforce + Data Cloud Build Tutorial

**How the whole thing was built, in the order you'd build it, with the *what*, the *where in Salesforce*, the *why*, and the *logic*.**

This is a teaching document. Read it top to bottom and you'll understand the entire system: a WooCommerce coffee store wired into Salesforce, with AI agents that shop *and* service customers, a Data Cloud unified profile, a real machine-learning churn model, web-behavior tracking, and an automated win-back marketing engine.

---

## How to read this

The build has **14 parts**, in dependency order — each part needs the ones before it:

```
 0. The big picture & the 4 golden rules        ← understand this first
 1. Org foundations (what to switch on)
 2. The CRM data model (the nouns)
 3. Connecting WooCommerce (getting real data in)
 4. The Apex service layer (the brains)
 5. Data Cloud (the unified customer)
 6. The agents (the conversation)
 7. The web chat plumbing (how chat reaches the agent)
 8. Web engagement tracking (knowing what people browse)
 9. Predictive — Einstein Studio (the churn model)
10. Marketing activation (the win-back engine)
11. Automation & scheduling (what runs by itself)
12. Security model (identity + consent + permissions)
13. Deployment (shipping it to a new org)
14. Testing & verification (proving it works)
15. What happens where, by use case (record-level flows)  ← start a return, see exactly what's created where
```

A note on conventions you'll see everywhere:
- **DLO** = Data Lake Object (suffix `__dll`) — raw data inside Data Cloud.
- **DMO** = Data Model Object (suffix `__dlm`) — the cleaned/modelled version.
- **CI** = Calculated Insight (object suffix `__cio`) — a saved SQL aggregation in Data Cloud.
- **MIAW** = Messaging for Web — Salesforce's embeddable web chat.
- `__c` = a custom field or object. `ssot__…__dlm` = a *standard* Data Cloud object.

---

## Part 0 — The big picture & the 4 golden rules

### The business problem

Kwitko sells coffee on a WooCommerce (WordPress) store. The goal: give every shopper a smart concierge that can **recommend coffee, recover abandoned carts, handle post-purchase offers, and resolve service issues** (orders, tracking, returns, refunds, cancellations) — all in one chat — while back-office automation predicts who's about to stop buying and wins them back.

### The architecture in one picture

```
        WordPress / WooCommerce storefront
        │  (orders, carts, product views, logins)
        │
   ┌────┼─────────────────────────────────────────────┐
   │    ▼                                               │
   │  Webhooks + REST + Named Credential   ◄─ Part 3    │
   │    │                                               │
   │    ▼                                               │
   │  Salesforce CRM  (Accounts, Orders, Leads, Cases) ◄─ Part 2
   │    │            ▲                                   │
   │    │            │  Apex service layer  ◄─ Part 4    │
   │    ▼            │                                   │
   │  Data Cloud  ◄──┘   (unified profile + insights) ◄─ Part 5
   │    │                                               │
   │    ▼                                               │
   │  Einstein Studio churn model  ◄─ Part 9            │
   │    │                                               │
   │    ▼                                               │
   │  Agentforce agents  ◄─ Part 6                      │
   │    │   (shop + service, one brain)                 │
   │    ▼                                               │
   │  Messaging for Web chat  ◄─ Part 7  ──► back to storefront
   │                                                     │
   │  Win-back campaign + emails  ◄─ Part 10            │
   └─────────────────────────────────────────────────── ┘
```

### The 4 golden rules (these explain *why* almost every design choice was made)

1. **DX/CLI/API first, the screen last.** Almost everything — objects, Apex, flows, Data Cloud maps, agents — is authored as metadata and deployed with the `sf` CLI. The browser is only used for the handful of genuinely UI-only steps (creating a CRM data stream, training the model, attaching chat user-verification). This makes the whole build *reproducible*.

2. **Deterministic for money, AI for words.** The agent never invents a product, price, or discount. A plain Apex engine (`RecommendationStrategyService`) decides *what* to recommend and *what* discount to give, from data and a discount table. The AI only phrases it. This is the anti-hallucination rule.

3. **Identity-gated for personal data.** A shopper sees order history, addresses, or lifetime value **only** after they're verified — either signed into WordPress (a server-rendered email we can trust) or after passing an email one-time-code. "I'm John" is never enough.

4. **Consent-gated for outreach.** No marketing email goes out unless `Email_Consent__c = true`, re-checked at send time. This is enforced in code, not left to the agent's judgment.

Keep these four in mind and the rest of the system makes sense.

---

## Part 1 — Org foundations (what to switch on first)

Before any metadata deploys, the org needs these capabilities enabled. These are one-time, mostly irreversible toggles done in Setup. **Do them first** — later steps fail without them.

| What | Where in Setup | Why |
|---|---|---|
| **Person Accounts** | Setup → Account Settings (then a support/enablement step) | A coffee shopper is a *person*, not a company. Person Accounts let one record hold a human's name + email + address. **Irreversible** once on. |
| **Agentforce** | Setup → Agentforce / Einstein setup | Turns on the AI agent platform (agents, topics, actions). |
| **Data Cloud** | Setup → Data Cloud Setup | Provisions the data lake, DMOs, Identity Resolution, Calculated Insights. |
| **Messaging for Web** | Setup → Messaging Settings | Enables the embeddable web chat (MIAW). |
| **Omni-Channel** | Setup → Omni-Channel Settings | Needed to route a chat session to an agent (or a human fallback). |

**The DX project.** The whole codebase is a Salesforce DX project:
- `sfdx-project.json` — declares the package, source API version `66.0`.
- `force-app/main/default/…` — all metadata, organized by type (`objects/`, `classes/`, `flows/`, `aiAuthoringBundles/`, etc.).
- `manifest/package.xml` — the deploy manifest.
- `scripts/deploy/deploy-to-new-org.sh` — the one-command deployer (covered in Part 13).
- `tools/` — the predictive-pipeline scripts and the live verification script.

**Why DX:** every component is a text file under version control, deployable to a fresh org with one script. That's golden rule #1 in practice.

---

## Part 2 — The CRM data model (the nouns)

Before behavior, you need the **things** the system talks about. The design rule here is **standard objects before custom ones**: use Salesforce's built-in Account, Order, Lead, Case, ReturnOrder, Shipment, Product2 wherever possible, and only invent custom objects for genuinely new concepts (carts, the customer journey, web events, training snapshots).

### 2.1 Standard objects, extended with custom fields

These already exist in Salesforce; we added fields so they can mirror WooCommerce and carry AI signals.

**Account** (Person Account) — *Setup → Object Manager → Account*. The customer.
- *Integration:* `Woo_Customer_Id__c` (external ID) — the link to the WooCommerce customer.
- *Profile:* `Customer_Status__c` (Prospect vs Customer), `Coffee_Preferences__c` (JSON of roast/origin/etc.), `Email_Consent__c` + `Email_Consent_Date__c`.
- *Churn & value:* `Churn_Score__c` (0–1, the daily heuristic), `Churn_Risk_Tier__c` (A/B/C), `Predicted_LTV__c`, `Value_At_Risk__c`, `Last_Scored__c`.
- *Data Cloud cache:* `Data_Cloud_Churn_Risk__c` (the **AI model** score, written as text like `"0.96 (AI model v2)"`), plus `Data_Cloud_Lifetime_Value__c`, `Data_Cloud_Order_Count__c`, `Data_Cloud_Segment__c`, `Data_Cloud_Next_Best_Action__c`, and more — these are *cached* copies of Data Cloud insights so agents can read them with a fast SOQL query.
- *Web engagement:* `Web_Events_30d__c`, `Web_Last_Seen__c`.

> **Why two churn fields?** `Churn_Score__c` is the always-fresh rule-of-thumb (recency/frequency). `Data_Cloud_Churn_Risk__c` is the real ML model's verdict. The marketing engine prefers the model when present, falls back to the heuristic. (More in Part 9.)

**Order** — *Object Manager → Order*. The revenue record, mirrored from Woo.
- `Woo_Order_Id__c` (external key), `Woo_Status__c`, `Source__c` (Ecommerce/Manual), `Payment_Status__c`, `Date_Paid__c`.
- *Fulfillment truth:* `Fulfillment_Status__c` (Not Shipped → Shipped → Delivered → Returned…), `Tracking_Number__c`, `Tracking_Url__c`, `Carrier__c`, `Last_Status_Change__c`.
- *Cancellation audit:* `Cancellation_Source__c`, `Cancelled_By__c`, `Cancelled_Date__c`, `Cancellation_Reason__c`.
- `Last_Woo_Sync__c` — timestamp of the last sync, so you can see freshness.

**Product2** — the coffee catalog. Added `Woo_Product_Id__c` plus *structured taste attributes* — `Bean_Type__c`, `Brew_Style__c`, `Roast_Level__c`, `Is_Decaf__c`, `Is_Flavored__c`, `Stock_On_Hand__c`. These attributes are what the recommendation engine filters on (Part 4).

**Lead** — a pre-purchase prospect (e.g., someone who abandoned a cart before buying). Added `Person_Account__c` (link a recovery lead to a known customer), `Converted_Account__c` / `Converted_Order__c` (closure), `Email_Consent__c`, `Chat_Summary__c`, `Cart_Status__c`. A Lead is "closed" when the person finally buys.

**Case** — support tickets. Added `Order__c`, `Category__c` (Shipping/Return/Refund/…), `Summary__c`, `Resolution__c`.

**Shipment / ReturnOrder** — standard fulfillment objects, with custom fields for carrier/tracking and return reasons. Using these standard objects (instead of inventing our own) means Salesforce reporting and future Order Management "just work".

### 2.2 Custom objects (genuinely new concepts)

*Setup → Object Manager → each object.*

- **`Cart__c` + `Cart_Item__c`** — an in-flight shopping cart and its lines. Holds either a known `Customer__c` or a `Lead__c`, the `Shopper_Email__c`, `Status__c` (Open/Abandoned/Recovered/Converted), value, and `Email_Consent__c`. *Why:* you can't recover a cart you didn't capture; this is the foundation of abandoned-cart recovery.
- **`Coupon__c`** — a personalized discount code, mirrored into WooCommerce so it's actually enforceable at checkout. Tracks `Status__c` (Issued/Redeemed/Expired) and the `Woo_Coupon_Id__c`.
- **`Customer_Journey__c`** — **the orchestrator's memory.** One row per email (it's the unique/external-ID key). Tracks `Last_Stage__c`, `Last_Agent__c`, `Recommended_Product_Ids__c`, `Purchased_Product_Ids__c`, `Post_Purchase_Done_Order_Ids__c`, and coupon redemption fields. *Why:* multiple agents act on the same person; this single record stops them from double-recommending or double-emailing.
- **`Agent_Interaction__c`** — an append-only **audit log**: every agent action (who/what/result), auto-numbered. *Why:* traceability and debugging — you can reconstruct exactly what each agent did.
- **`Order_Analytics__c`** — a denormalized snapshot of order + demographics, purpose-built to feed Data Cloud Calculated Insights without expensive joins.
- **`Web_Event__c`** — a single web-behavior event (page view, product view, add-to-cart, dwell). Starts anonymous (`Device_Id__c`) and gets *stitched* to an `Account__c` once we learn the email. (Part 8.)
- **`Churn_Training__c`** — a point-in-time **ML training snapshot** (features + the churned label). (Part 9.)
- **`Woo_Settings__c`** (custom setting) — holds the `Webhook_Secret__c` used to verify incoming webhooks.
- **`Chat_Verification__c`** — short-lived email one-time-codes for chat identity verification (hashed, with expiry + attempt limit).

### 2.3 Custom metadata: the discount table

**`Discount_Rule__mdt`** — *Setup → Custom Metadata Types → Discount Rule*. A configuration table, **not** data. Each row is a rule keyed by **buyer segment × channel** (e.g., `New_chat`, `VIP_post_purchase`, `Lapsed_abandoned_cart`) and defines `Percent__c`, `Min_Basket__c`, perks, etc.

> **Why metadata, not code or data:** you can change the discount strategy by editing a row — no code deploy, and it's version-controlled. The recommendation engine reads this table to decide the offer. This is golden rule #2: the *discount* is deterministic and table-driven, never the AI's invention.

---

## Part 3 — Connecting WooCommerce (getting real data in)

Now wire the store to Salesforce. The principle: **WooCommerce is the source of truth for orders**; Salesforce mirrors it, with two independent paths so nothing is missed.

### 3.1 The secure connection — Named Credential

**`WooCommerce`** named credential — *Setup → Named Credentials*. Points at the storefront URL and holds the WooCommerce REST API key. *Why:* Apex can call WooCommerce (`callout:WooCommerce/wp-json/wc/v3/...`) without secrets ever appearing in code.

### 3.2 Path A — real-time webhooks (fast)

- **`WooWebhookResource`** — an Apex `@RestResource` at `/woo/order/*`. WooCommerce calls it whenever an order changes.
- **Security:** it verifies an **HMAC-SHA256 signature** against the shared secret in `Woo_Settings__c`. A request that isn't signed with the secret is rejected — so a stranger can't POST fake orders.
- It hands the payload to **`WooOrderService.ingestOrder()`**, which:
  1. Upserts the Person Account by email.
  2. Creates the Order + OrderItems (matching products by `Woo_Product_Id__c`).
  3. Reconciles status/payment/tracking from Woo (so a Woo-side cancellation flows back).
  4. Captures email consent from checkout.
  5. Triggers downstream logic (journey memory, coupon redemption tracking, lead closure, Data Cloud refresh).
  - It's **idempotent** on `Woo_Order_Id__c` — re-delivering a webhook never creates a duplicate.

### 3.3 Path B — scheduled pull (reliable backstop)

**`WooOrderPull`** (Schedulable) — every ~15 minutes, fetches the most recent orders from Woo via the Named Credential and runs them through the same `ingestOrder()`. *Why:* webhooks occasionally fail or arrive late on low-traffic stores. The pull guarantees an order shows up within 15 minutes even if its webhook was lost. Because `ingestOrder` is idempotent, running both paths is safe.

### 3.4 Outbound — Salesforce → WooCommerce

When an agent does something, it must reflect back into Woo:
- **`WooOrderActionService`** — cancel an order, issue a refund (hits the payment gateway via `api_refund=true`), update a shipping address.
- **`WooCouponService`** — create a real single-use percentage/fixed coupon in Woo so the code the agent gives actually works at checkout.
- **`WooCustomerService`** — push profile/consent edits back.
- **`WooProductSync`** (+ the `Sync_Product_to_WooCommerce` flow) — when a product changes in Salesforce, push it to Woo.

> **The pattern to notice:** every external call goes through a small, named service class. Callouts happen **before** any database writes (Salesforce forbids "uncommitted work" before a callout), and everything is idempotent. This is why the integration is robust.

---

## Part 4 — The Apex service layer (the brains)

This is the biggest layer — ~68 working classes (plus ~30 test classes). **The agents are deliberately "dumb"**: they call these services for every real decision. Here's the layer grouped by job. You don't need every class memorized — understand the *groups* and the few keystone classes.

### 4.1 The recommendation engine (the keystone)

**`RecommendationStrategyService`** — the single brain that decides what to recommend and what discount to offer.
- **Input:** email, channel (chat / post_purchase / abandoned_cart), preference filters.
- **Logic:**
  1. *Classify the buyer* — New / Occasional / Recurrent / VIP / Lapsed, from order count + lifetime value + recent purchases.
  2. *Build an exclude set* — never re-offer what they already bought, already saw, or returned.
  3. *Pick the coffee* — hard-filter on the taste axes (`Bean_Type__c`, `Brew_Style__c`, `Roast_Level__c`); if nothing matches every filter, **gracefully relax** roast → brew → bean until something fits (and report what was relaxed).
  4. *Add a complementary item* — gear that's co-purchased with the coffee.
  5. *Resolve the discount* — look up `Discount_Rule__mdt` by buyer-type × channel.
  6. *Guardrail* — if the customer is in a service-recovery situation (a recent return), don't lead with a coupon.
- **Output:** primary product, complementary product, discount %, the rationale, plus any Data Cloud context.

> **Why it's central:** every agent (chat concierge, post-purchase, cart recovery) routes recommendations through this one engine, so the brand gives *consistent* advice everywhere — and it never hallucinates a product or price (golden rule #2).

Supporting it: **`ProductSuggestionService`** (returns only real, in-stock best-sellers so the agent can propose extras without inventing them), **`CustomerPreferenceService`** (reads/saves taste prefs), **`CoffeeAttributeBackfill`** (one-time job that filled in the taste attributes on the catalog).

### 4.2 The agent context & memory (cross-agent coordination)

- **`AgentContextService`** — the **privacy-gated context packet** every agent reads first. Given an email + the verified email, it returns: identity-verified yes/no, a plain-English summary (recent orders, open cases, saved cart, Data Cloud segment), and a recommended handoff target. **Personal fields are blanked when the shopper isn't verified.**
- **`JourneyService`** + **`JourneyLogger`** — read/write `Customer_Journey__c` and append to `Agent_Interaction__c`. This is how the system remembers "we already recommended X" and "we already emailed this order's offer", preventing duplicates.
- **`EmployeeAgentContextService`** — the trusted-record version for back-office agents working a Lead/Order (no customer to verify).

### 4.3 Identity & consent gates (the safety rails)

- **`IdentityService`** — the gate. `isVerified(requestedEmail, verifiedEmail)` returns true only if a trusted signed-in email matches, **or** the email passed an email-OTP recently. Fail-closed: no signal → no personal data.
- **`VerificationService`** + the **`RequestVerificationCodeAction`** / **`VerifyCodeAction`** invocable actions — the email one-time-code flow (6 digits, 10-minute expiry, hashed, 3-attempt limit). This is how a guest *becomes* verified inside a chat without a password.
- **`ConsentService`** — a tiny, side-effect-free check of `Email_Consent__c`. Designed to be the **first** action an outreach agent runs.

### 4.4 The service-desk actions (what the Service agent can actually do)

Each is an `@InvocableMethod` the agent calls; each enforces the identity gate where money or PII is involved:
- **`OrderStatusService`** — read order status + items + whether it can still be cancelled/returned.
- **`TrackingService`** — carrier + tracking link.
- **`ReturnService`** — full return: eligibility → create ReturnOrder → refund in Woo → email a label → flag the account for win-back → open a Returns case.
- **`CancellationService`** — cancel a not-yet-shipped order + refund.
- **`StoreCreditService`** — issue goodwill store credit (capped, e.g. $50).
- **`CaseService`** — open a support case and escalate to the human queue.
- **`ReshipService` / `ExchangeService` / `AddressUpdateService` / `OrderModifyService`** — the rest of the service toolkit.
- **`FulfillmentTruthService`** — the **single source of truth** for "what's the real status of this order?", reconciling Shipment vs the legacy Order field so the agent never says "Delivered" when it's only "Shipped".
- **`KwitkoServiceUtil`** — shared lookups (find the account, resolve an order by Woo ID / number / SF ID, eligibility checks).

### 4.5 Marketing & lifecycle services

- **`EmailService`** — the **one** consent-gated send path. Re-checks consent at send time, prefers a verified sending domain, and **batches all messages into a single `Messaging.sendEmail` call** (Salesforce limits you to ~10 send invocations per transaction — an early bug sent one-at-a-time and blew the limit; this was the fix).
- **`PostPurchaseService`** — builds the buy-again offer for a new order (consent → recommend via the engine → create coupon → push to Woo → email).
- **`LeadNurtureService`** — the abandoned-cart recovery brain (reconstruct the cart, get a fresh strategy, build a one-click restore link, issue a coupon, email).
- **`CartRestoreService` / `CartLinkService`** — rebuild a saved cart and produce a one-click "add it all back + apply coupon" link.
- **`AtRiskCampaignBuilder`** — the win-back campaign engine (Part 10).
- **`ChurnScoreService`** — the daily heuristic scorer (Part 9).
- **`LeadLifecycleService`** — closes open leads when the person finally buys.

### 4.6 Engagement services

- **`EngagementRest`** — public Apex REST endpoint `/engagement/*` the website posts browsing events to.
- **`EngagementIngestService`** — writes the `Web_Event__c` rows.
- **`IdentityStitchService`** — links anonymous device events to a person once the email is known (Part 8).

### 4.7 The headless bridge

**`AgentInvoker`** — lets Apex or a Flow run an agent *without* a chat window: `AgentInvoker.callAgent('Product_Advisor', 'message')`. *Why:* agents are conversational by nature, but a lot of work is event-driven (a new order, an abandoned cart). This bridge fires an agent from a scheduled job or a record-triggered flow.

---

## Part 5 — Data Cloud (the unified customer)

CRM holds records; Data Cloud turns them into **one unified customer** you can analyze and segment. The flow is always the same five steps:

```
Data Stream  →  DLO (__dll)  →  DMO (__dlm)  →  Identity Resolution  →  Calculated Insight (__cio)
 (ingest)        (raw lake)      (modelled)       (one person)            (saved SQL aggregate)
```

### 5.1 Data Streams — ingest CRM objects into the lake

*Data Cloud app → Data Streams.* A stream copies a Salesforce object into Data Cloud on a schedule. We stream `Account`, `Order_Analytics__c`, `Web_Event__c`, `Churn_Training__c`, and the fulfillment objects. Each lands as a **DLO** (e.g. `Web_Event_c_Home__dll`).

> **The one genuinely UI-only step.** Creating a *new* CRM data stream can't be done by metadata on a fresh org — deploying the definition fails with `no MktDataTranObject named X_Home found`, because the connector reads the object's schema at setup time. So you create the stream once in the UI (Data Streams → New → Salesforce CRM → pick the object), and *then* everything built on top of it (maps, insights) is fully metadata-deployable. The repo carries `dataStreamDefinitions/`, `dataSourceObjects/`, and `mktDataTranObjects/` so they're tracked, and the deploy script runs them as a **non-fatal** step.

### 5.2 DLO → DMO mapping — model the raw data

*Data Cloud → Data Mapping.* A DLO is raw; a **DMO** is the clean, standardized shape. The mapping says "this DLO field fills that DMO field." The repo's `objectSourceTargetMaps/` holds 6 of these:

- **Account → `ssot__Individual__dlm`** — maps name/birthdate/etc. into Salesforce's *standard* unified Individual object.
- **Account → `ssot__ContactPointEmail__dlm`** — maps the email, so a person can be matched by email.
- **`Web_Event` / `Churn_Training` / `Order_Analytics` → their custom DMOs** — modelled copies for analytics and ML.

> **The single most important gotcha in Data Cloud — empty identity keys.** Identity Resolution produces **0 unified profiles** if the keys it matches on come from an *empty* field. The fix: map the Individual's PK and the email's PartyId from a **populated** field — `Account_Home__dll.Id__c` — not from something like `PersonIndividualId__c` (which is blank for Person Accounts). Map `Id__c → ssot__Individual__dlm.ssot__Id__c` and `Id__c → ssot__ContactPointEmail__dlm.ssot__PartyId__c`. Get this wrong and the whole unified profile is empty with no error message.
>
> **The second gotcha:** the "Select Objects" mapping modal takes **60–120 seconds** to load. It is not frozen. Wait.

### 5.3 Identity Resolution — collapse to one person

*Data Cloud → Identity Resolution.* A ruleset ("inCoffee Unified Profile") matches the source profiles by email and produces **one unified individual** per real human, even across devices. You create the ruleset in the UI (its nested rule schema is undocumented and errors are opaque), then run it via API:
```bash
sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<id>/actions/run-now" --method POST --body '{}'
```
Verify it worked: `SELECT COUNT(*) FROM Unified...__dlm` should be > 0.

### 5.4 Calculated Insights — saved SQL aggregations

*Data Cloud → Calculated Insights.* A CI is a SQL query Data Cloud runs on a schedule and stores as a `__cio` object. Ours include:
- **Web Engagement Profile v2** — per account: event count, total dwell seconds, last activity (feeds churn scoring + agent context).
- **Customer Agent Profile** — per account: order count, lifetime value, AOV, last order.
- **Customer Category Affinity** — what categories each customer favors.
- **Order Patterns by Demographics**, **Customer/Return Risk** — cohort and return analytics.

> **CI gotchas worth knowing:** a CI can read a DLO directly (no DMO needed for pure analytics). The SQL is strict — **no table aliases** (use the full DMO name as the qualifier), **output aliases must end in `__c`**, and **currency fields must be wrapped in `TRY_CONVERT_CURRENCY(...)`** with a literal target-currency dimension in both SELECT and GROUP BY. And critically: deploying a CI by metadata sometimes returns "Succeeded" but **silently doesn't provision** — so the live CIs were authored in the UI's SQL editor, with the metadata kept as documentation. (That's why it's "v2" — the first API name got orphaned by a failed deploy.)

### 5.5 How agents consume Data Cloud

`DataCloudAugmentationService` queries the unified profile + the CIs and **caches** the results onto the Account's `Data_Cloud_*` fields. *Why cache:* agents need answers in milliseconds during a live chat; a cached field is a fast SOQL read instead of a slow cross-system query.

---

## Part 6 — The agents (the conversation)

Now the part customers actually talk to. The design is **one orchestrator with specialist sub-agents (topics)**, all sharing the brain (Part 4) and the memory (the journey).

### 6.1 Agentforce concepts in 30 seconds

- An **agent** is the AI persona. Its definition lives in an **authoring bundle** (`aiAuthoringBundles/<Name>/<Name>.agent`) — *Setup → Agentforce → Agents*.
- A **topic** is a sub-skill with its own instructions (e.g. "service", "recommend").
- An **action** is a concrete capability a topic can invoke — almost always one of our Apex `@InvocableMethod` services.
- A **planner bundle** (`genAiPlannerBundles/`) is the compiled runtime mapping of topics → actions for a published version.
- **Agent type is immutable after first publish.** *Employee* agents run headlessly (back office); *Service* agents face customers on the web. Choose correctly the first time.

### 6.2 The agents we built

| Agent | Type | Job |
|---|---|---|
| **`Kwitko_Concierge_Web_Live`** | Service (web) | The customer-facing web concierge. Greets, shops, **and** services — all in one chat. |
| **`Kwitko_Concierge`** | Employee (headless) | The back-office twin, fired by Flows/Apex for event-driven work. |
| **`Product_Advisor`** | Employee | The recommendation specialist — wraps `RecommendationStrategyService`. Every other agent calls it so advice is consistent. |
| **`Inside_Sales`** | Employee | Abandoned-cart recovery. |
| **`Post_Purchase_Growth`** | Employee | Buy-again offers after an order. |

### 6.3 Inside the web concierge

The `Kwitko_Concierge_Web_Live` agent has four topics:
- **`agent_router`** — greets and decides: shopping, service, or off-topic.
- **`concierge`** (shopping) — actions: `get_agent_context`, `lookup_customer`, `capture_lead`, `build_strategy`, `issue_coupon`, `add_to_cart`, `restore_cart`.
- **`service`** — actions: `get_order_status`, `get_tracking`, `process_return`, `cancel_order`, `apply_store_credit`, `open_case`, `request_verification_code`, `verify_code`, `sign_in_link`.
- **`off_topic`** — politely redirects.

Its variables carry the verified identity: `loggedInEmail`, `loggedInFirstName`, `cartToken` — populated from hidden pre-chat fields (Part 7).

**The flow of a single message:** the agent reads the message → router picks a topic → the topic calls `get_agent_context` first (to load memory + check verification) → calls the right Apex action → the Apex does the real work and returns a result → the agent phrases it. Notice the AI never decides the *facts* — it orchestrates the services.

### 6.4 Why one orchestrator instead of many bots

Because a shopper switches intent mid-sentence ("actually, where's my last order?"). One agent that can pivot between shopping and service in the same session — sharing one lead, one journey, one verified identity — gives a seamless experience and avoids the double-actions you'd get from disconnected bots.

---

## Part 7 — The web chat plumbing (how a chat reaches the agent)

This is the wiring between the WordPress storefront and the agent. It's the part with the most small pieces, so here's the **path a chat takes**, then each piece.

```
Visitor clicks "Chat"  (WordPress page)
   │  WPCode snippet sets hidden fields (loggedInEmail, name, cartToken)
   ▼
MIAW widget  ──►  Embedded Service Deployment  ──►  Messaging Channel
   │                                                     │
   ▼                                                     ▼
A MessagingSession record is created in Salesforce
   │
   ▼
Session-handler Flow  "Kwitko_Web_Chat_Routing"
   │  routeWork(routingType = Copilot)
   ▼
Agentforce Service Agent  "Kwitko_Concierge_Web"
   │  (if agent unavailable → fallback)
   ▼
Queue "Kwitko_Chat_Fallback"  → a human
```

### 7.1 The Salesforce side

- **Embedded Service Deployment** `Kwitko_Web_Chat_V2` — *Setup → Embedded Service Deployments*. The chat widget config: which site serves it, branding, guest access on, which pre-chat fields exist (and that they're hidden/auto-filled). Uses **WebV2** (modern MIAW).
- **Messaging Channel** `Kwitko_Web_Chat_V2` — *Setup → Messaging → Messaging Channels*. Defines the **hidden pre-chat fields** that carry identity: `Kwitko_Logged_In_Email__c`, `Kwitko_Logged_In_First_Name__c`, `Kwitko_Cart_Token__c`. Names the session-handler flow and the fallback queue.
- **Routing Flow** `Kwitko_Web_Chat_Routing` — *Setup → Omni-Channel → Routing Flows*. On a new session, calls `routeWork` with `routingType = Copilot` to hand the chat to the agent; falls back to a human queue if needed.
- **Queue** `Kwitko_Chat_Fallback` + **Queue Routing Config** `Kwitko_Chat_Routing` — *Setup → Omni-Channel*. Where escalations land.
- **Public Site** `ESW_Kwitko_Web_Chat_…` — *Setup → Sites*. Gives guests (not logged into Salesforce) a URL to reach the chat and the engagement endpoint.
- **CORS** `Kwitko_Storefront` + **CSP Trusted Site** `Kwitko_Storefront` — *Setup → Security → CORS / CSP*. Whitelist the WordPress origin so the browser can call Salesforce, and so the agent's links (sign-in, account) aren't redacted.

### 7.2 The identity path (the part that was hardest)

The only **trusted** identity is `loggedInEmail`, rendered **server-side** by WordPress from the logged-in user (not spoofable by the browser). The agent uses it as the `verifiedEmail` for gated actions. If it's empty (a guest), the agent falls back to the email-OTP flow (Part 4.3).

> **Lessons baked in here:** (1) the hidden field must be set **inside** the `onEmbeddedMessagingReady` handler, or it's empty for guests; (2) the field name must be **exactly** `Kwitko_Logged_In_Email__c`; (3) we deliberately *don't* rely on JWT `setIdentityToken`, because that path is silently ignored unless Salesforce Support attaches a verification keyset to the deployment — the server-rendered hidden field is the reliable route.

### 7.3 The WordPress side (WPCode snippets)

Three PHP snippets installed in WordPress (via WPCode), each "auto-insert, run everywhere":
- **Chat identity** — detects the logged-in WP user, and on chat-ready sets the hidden fields + calls `window.kwitkoIdentify(email, first)` so browsing history stitches to the person.
- **Engagement tracker** — see Part 8.
- **Cart capture** — on every cart change, HMAC-signs the cart contents and posts them to Salesforce, so an abandoned cart is recoverable with its exact items.

---

## Part 8 — Web engagement tracking (knowing what people browse)

To recommend well and to predict churn, the system needs to see browsing — not just purchases.

### 8.1 The capture path

The WordPress **engagement snippet** drops a cookie (`kwitko_dev`, a persistent device ID) and posts events to the Salesforce Site REST endpoint:
```
POST /woo/services/apexrest/engagement
{ deviceId, sessionId, events:[{type:"pageView", pageUrl, productId, dwell…}], identify:{email,first,last} }
```
- **`EngagementRest`** receives it → **`EngagementIngestService`** writes `Web_Event__c` rows → **`IdentityStitchService`** links them to a person if an email is known.
- Events start **anonymous** (device only). The moment the shopper logs in or types their email at checkout, the `identify` block arrives and the stitch links all that device's past events to their Account.

### 8.2 Self-healing identity stitch

`IdentityStitchService` picks the **oldest** Person Account for an email as canonical, collects every device ID ever seen for that email or any duplicate account, and relinks all events to the canonical account. *Why:* two simultaneous logins can briefly mint duplicate accounts; the next stitch automatically collapses them. It's idempotent.

### 8.3 Why custom REST instead of the Data Cloud Web SDK

Salesforce has a Web SDK connector for browser tracking, but it isn't available on this org (only Web Service Consumer / WebSockets sources appear). So the build uses a **custom Apex REST endpoint** as the capture route. This isn't a workaround gap — it's the deliberate architecture for this org, and it feeds Data Cloud through the `Web_Event__c` stream just the same.

### 8.4 Into Data Cloud

`Web_Event__c` streams to `Web_Event_c_Home__dll` → `__dlm`, joins to the unified individual, and the **Web Engagement Profile v2** CI aggregates per-person dwell/recency — which then feeds both the churn score and the agent's context.

---

## Part 9 — Predictive: Einstein Studio (the churn model)

This is the real machine-learning piece: a model that predicts which customers are about to stop buying.

### 9.1 Build the training data (point-in-time snapshots)

`tools/generate_churn_training.apex` builds `Churn_Training__c` rows. The discipline that makes this a *valid* model:
- Each row = **one customer at one past reference date**.
- **Features** are computed only from history **before** that date — orders, spend, AOV, recency, tenure, cadence, momentum, plus web engagement (`Web_Events_30d__c`, `Web_Dwell_Total__c`, `Web_Days_Since_Seen__c`).
- The **label** `Churned__c` = "did NOT order within 60 days **after** that date."
- **No leakage:** never use anything from after the reference date as a feature. (Our first model hit AUC .978 *with* the Account ID included and flagged a leakage warning; retraining without identifiers gave the same .978 — proving the signal is genuinely in purchase behavior.)

### 9.2 Train the model (the 7-step Model Builder — UI)

*Data Cloud → AI Models → Add Predictive Model.* The wizard:
1. **Type** — Binary classification.
2. **Select Data** — the DMO `Churn_Training_c_Home__dlm` (must be a DMO, not a DLO).
3. **Training Data** — all records.
4. **Set Goal** — predict `Churned__c = TRUE`.
5. **Prepare Variables** — exclude identifier columns (Account ID, row ID) so the model learns behavior, not memorized IDs.
6. **Algorithm** — automatic.
7. **Save & Train** — ~5 minutes on this data; then **Activate** the version.

Result: model **"Predicted Churned" v2, AUC 0.978**, active and usable from Flows, Apex, and predict jobs.

### 9.3 Score with a predict job

*Model detail → Integrations → Predict Jobs.* The job scores the input DMO and writes a `Churn_Predictions__dlm` row per customer with the churn probability.
> **Gotcha:** a *streaming* predict job does **not** score rows that already existed when you activated it. Use the row-action **Run** (or a Batch job) to force a one-time scoring of the current data. That's what produced our 161 prediction rows.

### 9.4 Write scores back to the Account

`tools/sync_model_scores.apex` joins predictions → training row → Account and writes `Account.Data_Cloud_Churn_Risk__c = "0.96 (AI model v2)"`.
> **Gotchas that will bite you again:** `ConnectApi.CdpQuery` returns 0 rows for cross-DMO joins (use the REST `/ssot/query-sql` path instead); `query-sql` is eventually-consistent (retry with backoff); deleting the training rows full-refreshes the DMO and orphans the predictions (recover the PK→Account map with `... ALL ROWS`, which still sees deleted rows for 15 days); `emptyRecycleBin` caps at 200 records per call (batch it).

### 9.5 The two-tier scoring design (why both scores exist)

- **`Churn_Score__c`** — the **operational** score. `ChurnScoreService` runs **daily** and computes a fresh heuristic from recency vs. normal cadence, *damped* by recent web engagement (browsed in the last 14 days → multiply risk by 0.6). Always present, always fresh.
- **`Data_Cloud_Churn_Risk__c`** — the **strategic** score from the Einstein model. More accurate, but only as fresh as the last predict run.
- Downstream consumers prefer the model score when present and fall back to the heuristic. Best of both: always-on coverage + ML accuracy.

### 9.6 The 5 MB storage trap (this org is tiny)

Developer Edition has **5 MB** of data storage. The training/scoring rows (~hundreds of records) can't *coexist* with the live web tracker — when storage fills, the engagement endpoint silently returns `STORAGE_LIMIT_EXCEEDED` behind an HTTP 200 (the browser `fetch` won't even throw). So scoring is **transient**: generate rows → wait for stream sync → train/predict → write scores back → **delete + `emptyRecycleBin`** → verify the tracker recovered. `tools/cleanup_transient_storage.apex` automates the purge. This constraint is *why* the model isn't retrained continuously on this org.

---

## Part 10 — Marketing activation (the win-back engine)

Predicting churn is useless unless you act on it. This is the action.

**`AtRiskCampaignBuilder`** — runs daily:
1. **Select** consented accounts where `Predicted_LTV__c ≥ 200` **and** churn is high (`Data_Cloud_Churn_Risk__c` present, else `Churn_Score__c ≥ 0.70`). It prefers the AI model score, parsing the leading decimal out of the `"0.96 (AI model v2)"` text.
2. **Add** them as members of the Classic campaign **"DC - High-Value At-Risk Win-Back"** (idempotent — never double-adds).
3. **Flag Tier-A** (highest value-at-risk) accounts with a follow-up **Task** for a human's personal outreach.
4. **`sendWinBack()`** emails pending members via the consent-gated `EmailService`, marking each `CampaignMember.Status = 'Emailed'` so no one is mailed twice. The copy is honest (no fake coupon codes — it drives to the chat concierge, which *can* issue real credit), and personalizes on recent browsing ("we noticed you've been browsing").

*Where to see it:* Campaigns (Classic) → "DC - High-Value At-Risk Win-Back" → Campaign Members + their statuses.

> Note: this runs on **standard Classic Campaigns**, not Marketing Cloud — no extra licensing. It's a complete predict → segment → activate → email loop entirely inside core Salesforce.

---

## Part 11 — Automation & scheduling (what runs by itself)

Two kinds of automation: **Flows** (declarative, event-triggered) and **scheduled Apex** (time-triggered sweeps).

### 11.1 Flows — *Setup → Flows*

| Flow | Trigger | What it does |
|---|---|---|
| `Kwitko_Web_Chat_Routing` | New web chat session | Routes the chat to the Service agent (Part 7). **Active.** |
| `Abandoned_Cart_to_Lead` | `Cart__c` becomes "Abandoned" | Calls `AbandonedCartService` → creates/links a Lead for recovery. **Active.** |
| `Order_Close_Lead_On_Purchase` | Any Order for a Person Account | Calls `LeadLifecycleService` → closes that customer's open leads. **Active.** |
| `Winback_On_Return` | `Account.Winback_Needed__c = true` | Enqueues a confidence-rebuild offer after a return. **Active.** |
| `Sync_Product_to_WooCommerce` | Product2 changed | Pushes the change to Woo. **Active.** |
| `Auto_Post_Purchase_Offer` / `Auto_Invoke_PostPurchase_Agent` | New e-commerce order | Two designs for post-purchase offers (the scheduled sweep is the live path; these are the Flow-invokes-agent demonstrations, kept as Draft). |

### 11.2 Scheduled Apex — *Setup → Scheduled Jobs*

These are `Schedulable` classes. They run as a **privileged user** (not the locked-down web guest), which is exactly why event-driven work is done in sweeps rather than guest-context flows.

| Job | Cadence | Purpose |
|---|---|---|
| `AbandonedCartSweep` | every 15 min | Mark carts abandoned after ~1h of inactivity → fires the recovery flow. |
| `CartRecoverySweep` | periodic | Send recovery offers for abandoned carts with consent (idempotent via a "recovery sent" stamp). |
| `Chat_Nurture_Sweep` | periodic | Nurture recent website-chat leads who haven't purchased. |
| `PostPurchaseSweep` | ~hourly | Find new e-commerce orders without an offer yet → enqueue the buy-again offer. |
| `WooOrderPull` | every 15 min | The reliable order-ingestion backstop (Part 3.3). |
| `Kwitko Churn Scoring Daily` (`ChurnScoreService`) | 03:00 | Refresh the operational churn score on every customer. |
| `Kwitko At-Risk Campaign Daily` (`AtRiskCampaignBuilder`) | 03:30 | Build the campaign + send win-back emails (Part 10). |

> **Important:** the schedules are **not** in the code — you set them after deploy with `System.schedule(...)` (the patterns are in the class comments). This keeps the metadata portable across orgs.

---

## Part 12 — Security model (identity + consent + permissions)

Three layers, all already met above — collected here so the model is explicit.

1. **Identity gate** (`IdentityService`) — no personal data without a verified email (signed-in or email-OTP). Fail-closed.
2. **Consent gate** (`ConsentService` + `EmailService`) — no marketing without `Email_Consent__c`, re-checked at send.
3. **Permission sets** — *Setup → Permission Sets*. Least-privilege bundles assigned post-deploy:
   - **`Kwitko_Integration`** — the workhorse: access to ~54 service classes, the custom objects (Cart/Coupon/Journey/etc.), order/case/product fields, and the WooCommerce external credential. Anything running sweeps or agents needs this.
   - **`Engagement_Tracking`** — `Web_Event__c` access for the tracking endpoint + stitch.
   - **`Predictive_Scoring`** — the churn/LTV fields on Account + the `Churn_Training__c` object.
   - **`Kwitko_Messaging_Ops`** — lets support staff close stuck chat sessions.
   - **`Kwitko_Chat_Verification`** (optional) — the OTP object, for staff who support verification.

> **The rule that bites everyone:** a new custom field is **invisible** (SOQL says "No such column", agents can't read it) until a permission set grants its field-level security. After deploying new fields, deploy *and assign* a permset. Always.

---

## Part 13 — Deployment (shipping it to a new org)

One script does it: `scripts/deploy/deploy-to-new-org.sh`. It enforces **dependency order** — you can't deploy a permission set that references a field that doesn't exist yet.

```
Preconditions (manual): Person Accounts, Agentforce, Data Cloud, Messaging, Omni-Channel ON
   ▼
1. Data model        objects, layouts, custom metadata
2. Apex              classes + triggers   (RunLocalTests must pass)
3. Integration       named credential, CSP, CORS
4. Omni-Channel      queues, routing configs
5. Messaging         messaging channel, embedded config, site
6. Flows             the 7 flows
7. Data Cloud        a) data source objects
                     b) streams + transforms   ← NON-FATAL (UI fallback if needed)
                     c) DLO→DMO maps
                     d) calculated insights
8. Security          permission sets, profiles   ← then ASSIGN the permsets
9. UI                apps, pages, tabs, LWC, assets
```

**Post-deploy, by hand** (the genuinely-not-metadata steps):
- **Publish the agents** — bundles are `.forceignore`'d; publish with `sf agent publish authoring-bundle --api-name <Name>`. Agent **type is immutable** after first publish.
- **Create any missing CRM data stream** in the Data Cloud UI, then re-run step 7.
- **Run Identity Resolution + Calculated Insights** via the REST `actions/run-now` / `actions/run` endpoints.
- **Set the Person Account default record type** on the admin profile (UI-only).
- **Schedule the jobs** with `System.schedule(...)`.
- **Fix email deliverability** — a `@gmail.com` From address fails Gmail's DMARC even though Apex reports success; use an Org-Wide Email Address on a domain you control with SPF + DKIM.

**The deploy mantra:** deploys are **async** — always confirm the final "Succeeded" with `sf project deploy report`, not the first component table.

---

## Part 14 — Testing & verification (proving it works)

The hard lesson that shaped this: **Apex tests passing ≠ the live system working.** So verification is two-tier.

1. **Apex tests** (~30 test classes) — regression guards: consent-revocation blocks a send, the identity gate refuses an unverified user, the model score overrides the heuristic, etc. Run with `sf project deploy start --test-level RunLocalTests`.
2. **The live proof** — `tools/verify_pipeline.sh` hits the *real* running system and checks 12 things end-to-end: the engagement endpoint actually inserts an event (and isn't storage-blocked), events stitch to people, Data Cloud ingested + unified them, the engagement CI exists, the model produced prediction rows **and** wrote scores back to Accounts, the daily jobs are scheduled, and win-back emails were sent + tracked. It mutates one test event and cleans it up.

> **The discipline:** every agent change is also smoke-tested in a **live browser chat** — log in, open a *new* chat, confirm the agent greets by name, returns *your* order, and refuses a *different* email. No "done" without the live check. (And don't run `sf agent test` on this 5 MB org — the AI Evaluation results are a silent storage hog that's UI-only to delete.)

---

## Part 15 — What happens where, by use case (record-level flows)

The earlier parts explain the *pieces*. This part answers the practical question: **when a customer does X, what record gets created or updated, in Salesforce vs in WooCommerce, and what else fires?** Each use case is a trace.

**How to read each trace:**
- 🟦 **Salesforce** = a record created/updated in your org.
- 🟧 **WooCommerce** = an outbound API call to the store (the exact REST endpoint).
- 🟩 **Side effects** = email, Data Cloud refresh, journey/audit logging.
- Every customer-facing action is also logged to **`Customer_Journey__c`** (memory, 1 per email) and **`Agent_Interaction__c`** (append-only audit). That's assumed below unless noted.

> **Two facts that surprise people:**
> 1. **Inventory is never written by Salesforce.** `Product2.Stock_On_Hand__c` is only *read* (to filter/rank recommendations). WooCommerce remains the single source of truth for stock — Salesforce never decrements or restocks it. (If you want SF to adjust inventory on returns/reships, that's a new build, not something currently wired.)
> 2. **Refunds move real money.** The return/cancel flows call Woo's `/refunds` with `api_refund=true`, which hits the payment gateway. That's why those actions are identity-gated.

---

### Use case 1 — New order placed (WooCommerce → Salesforce)

**Trigger:** customer checks out on the store. Woo fires the order webhook (`WooWebhookResource`), or the 15-minute `WooOrderPull` catches it. Both run `WooOrderService.ingestOrder()`.

```
🟧 Woo checkout ──webhook──► 🟦 Salesforce
```
| Record | Create/Update | What |
|---|---|---|
| 🟦 **Account** (Person) | Upsert by email | name, `Woo_Customer_Id__c`, consent, `Customer_Status__c='Customer'` |
| 🟦 **Order** | Insert | `Woo_Order_Id__c`, `Fulfillment_Status__c` (mapped from Woo), `Payment_Status__c`, shipping address, tracking |
| 🟦 **OrderItem** | Insert per line | matched to `Product2` via `Woo_Product_Id__c` |
| 🟦 **FulfillmentOrder + Shipment** | Insert (if tracking present) | via `FulfillmentTruthService.syncFromWoo()` |
| 🟦 **Customer_Journey__c** | Update | `Purchased_Product_Ids__c` appended, stage='Purchased' |
| 🟦 **Lead** | Update→closed | `LeadLifecycleService.closeForPurchase()` closes any open lead |

- 🟧 **Woo callout:** none (inbound only).
- 🟩 **Side effects:** coupon-redemption tracking (if the order used a journey coupon → `Customer_Journey__c.Coupon_Redeemed__c=true`); `DataCloudAugmentationService.refreshAccount()`.

---

### Use case 2 — Customer starts a RETURN  ⭐ (your example)

**Trigger:** shopper asks the chat agent to return an order. Identity-gated (a refund moves money). Runs `ReturnService.process()`.

```
🟦 SF: eligibility check (must be Delivered)
   │
   ├─🟧 Woo: POST /orders/{id}/refunds  (api_refund=true → REAL money back)
   │
   ▼
🟦 SF: ReturnOrder + lines, Case, Shipment(return label), Account flagged
   │
   └─🟩 email return label  +  Data Cloud refresh
```
| Record | Create/Update | What |
|---|---|---|
| 🟦 **ReturnOrder** | Insert | `Order__c`, `Return_Reason__c`, `Refund_Amount__c`, `Woo_Refund_Id__c`, return label URL + tracking |
| 🟦 **ReturnOrderLineItem** | Insert per item | the items being returned |
| 🟦 **Order** | Update | `Fulfillment_Status__c='Returned'/'Refunded'`, `Woo_Refund_Id__c` |
| 🟦 **Account** | Update | `Has_Returned_Order__c=true`, `Return_Count__c`++, `Last_Return_Date__c`, **`Winback_Needed__c=true`** |
| 🟦 **Shipment** | Insert (best-effort) | return label tracking, `Shipment_Status__c='Shipped'` |
| 🟦 **Case** | Insert | `Category__c='Returns'`, transcript in description, for CSR follow-up |

- 🟧 **Woo callout:** `POST /wp-json/wc/v3/orders/{wooOrderId}/refunds` with `api_refund=true` — issues the **real refund**.
- 🟩 **Side effects:** return-label email (transactional — sent even without marketing consent); `DataCloudAugmentationService.refreshAccount()`. The `Winback_Needed__c=true` flag later fires the **`Winback_On_Return`** flow → a win-back offer.
- ⚠️ **Inventory:** *not* touched — Woo stays source of truth. **Shipping:** a return Shipment record is created for the label; the original order's fulfillment status flips to Returned/Refunded.

---

### Use case 3 — Order cancellation

**Trigger:** shopper cancels a not-yet-shipped order. Identity-gated. Runs `CancellationService.cancel()`.

| Record | Create/Update | What |
|---|---|---|
| 🟦 **Order** | Update | `Fulfillment_Status__c='Cancelled'`, `Cancelled_By/Date/Reason`, `Woo_Refund_Id__c` |
| 🟦 **Case** | Insert | `Category__c='Order'`, cancellation record |

- 🟧 **Woo callouts (in order, before any SF write):** `PUT /orders/{id}` `{status:'cancelled'}` **then** `POST /orders/{id}/refunds` (`api_refund=true`).
- 🟩 Data Cloud refresh. Eligibility: only if status is *Not Shipped* or *Processing*.

---

### Use case 4 — Exchange / Reship

**Exchange** (`ExchangeService`): runs the **return leg** (use case 2 — ReturnOrder + real refund) **and** opens a `Category__c='Returns'` **Case** telling the warehouse which replacement to send.

**Reship** (`ReshipService`): no money moves — creates a brand-new **zero-price replacement Order + OrderItems** (`Source__c='Manual'`, all `UnitPrice=0`) cloned from the original, plus a `Category__c='Shipping'` **Case** for the warehouse. 🟧 No Woo callout.

---

### Use case 5 — Abandoned cart → recovery

**Trigger (capture):** the WordPress cart-capture snippet posts cart contents to Salesforce as a `Cart__c` (+ `Cart_Item__c`). After ~1h idle, `AbandonedCartSweep` marks it `Abandoned`, which fires the `Abandoned_Cart_to_Lead` flow → `AbandonedCartService`.

```
🟦 Cart__c='Abandoned' ─► 🟦 Lead created/linked ─► (later) 🟦 Coupon + 🟧 Woo coupon + 🟩 email
```
| Stage | Records | Woo / side effects |
|---|---|---|
| Abandon | 🟦 **Lead** insert/update (`LeadSource='WooCommerce Abandoned Cart'`), 🟦 **Cart__c** linked to Lead/Account | — |
| Recover (`LeadNurtureService`) | 🟦 **Coupon__c** insert, 🟦 **Lead** → 'Working - Contacted' | 🟧 `POST /coupons` (real one-time coupon, email-restricted); 🟩 consent-gated email with **one-click restore link** (re-adds items + applies coupon) |

---

### Use case 6 — Post-purchase buy-again offer

**Trigger:** new e-commerce order. `PostPurchaseSweep` (hourly) → `PostPurchaseService.buildOffer()`. Consent-gated; idempotent (one coupon per order).

| Record | Create/Update | Woo / side effects |
|---|---|---|
| 🟦 **Coupon__c** | Insert | 🟧 `POST /coupons` — percent coupon **scoped to the recommended products**, 30-day expiry |
| 🟦 **Order** | Update `Coupon_Code__c` | — |
| 🟦 **Customer_Journey__c** | `Recommended_Product_Ids__c` + `Post_Purchase_Done_Order_Ids__c` appended | 🟩 consent-gated email with AI copy + product photos |

Skips entirely if: no consent, order cancelled/returned/refunded, customer in service-recovery, or an offer already exists for the order.

---

### Use case 7 — Issue a coupon + redemption tracking

- **Issue** (`CouponService`): 🟧 `POST /coupons` (single-use `KW-{NAME}-{pct}-{rand}`); 🟦 `Customer_Journey__c` records the code + issue date.
- **Redemption** is detected automatically at the next **order ingest** (use case 1): when `Order.Coupon_Code__c` matches the journey's code → 🟦 `Customer_Journey__c.Coupon_Redeemed__c=true` + discount amount. (This is what powers coupon-efficiency analytics.)

---

### Use case 8 — Store credit (goodwill)

`StoreCreditService` (identity-gated, capped $50): 🟧 `POST /coupons` as a **fixed-cart** amount coupon (not percentage), email-restricted; 🟦 `Coupon__c` insert + journey log. No order/refund touched.

---

### Use case 9 — Case / escalation to a human

`CaseService`: 🟦 **Case** insert (`Origin='Chat'`, full transcript in description up to 32k), optional 🟦 **Task** with the transcript on the case timeline. If `escalate=true` → status Escalated, priority High, routed to the **`Kwitko_Chat_Fallback`** queue. 🟧 No Woo callout.

---

### Use case 10 — Address update (pre-ship)

`AddressUpdateService` (identity-gated): 🟧 `PUT /orders/{id}` with the new `shipping` block **first**, then 🟦 updates the Order's shipping fields. Only if status is *Not Shipped* / *Processing*.

---

### Use case 11 — Product edited in Salesforce → WooCommerce

Editing a `Product2` fires the `Sync_Product_to_WooCommerce` flow → `WooProductSync` (async): 🟧 `POST /products` (new) or `PUT /products/{id}` (existing); 🟦 stamps `Woo_Sync_Status__c` + `Woo_Last_Sync_Date__c` (or the error) back on the product. This is the one flow that goes **SF → Woo** for catalog.

---

### Use case 12 — Web browsing → identity stitch → Data Cloud

`EngagementRest` (public endpoint, from the WordPress tracker):
| Record | What |
|---|---|
| 🟦 **Web_Event__c** | one per event (page view, product view, add-to-cart, dwell, search) — anonymous by `Device_Id__c` |
| 🟦 **Account** | created/matched when an `identify{email}` arrives (`IdentityStitchService`) |
| 🟦 **Web_Event__c** (retro) | all prior events on that device/email **relinked** to the canonical account |

🟩 Then it flows into Data Cloud (`Web_Event` stream → DMO → unified profile → Web Engagement CI). No Woo callout.

---

### Use case 13 — Churn scoring → win-back campaign

- **Daily score** (`ChurnScoreService`): 🟦 updates `Account.Churn_Score__c`, `Predicted_LTV__c`, `Churn_Risk_Tier__c`, `Web_Last_Seen__c`. (The Einstein model separately writes `Data_Cloud_Churn_Risk__c`.)
- **Daily campaign** (`AtRiskCampaignBuilder`): 🟦 ensures the Classic **Campaign** "DC - High-Value At-Risk Win-Back", inserts **CampaignMember** rows for high-value at-risk consented customers, adds a **Task** for Tier-A; `sendWinBack()` 🟩 emails them (consent-gated) and flips each member to `Status='Emailed'`. No Woo callout.

---

### One-glance summary: which use cases call WooCommerce

| Use case | Writes Salesforce | Calls WooCommerce | Moves money | Touches inventory |
|---|---|---|---|---|
| New order (inbound) | ✅ | — | — | — |
| **Return** | ✅ | `POST /orders/{id}/refunds` | **Yes** | No |
| Cancellation | ✅ | `PUT /orders/{id}` + `/refunds` | **Yes** | No |
| Reship | ✅ (new $0 order) | — | No | No |
| Exchange | ✅ | refund (return leg) | **Yes** | No |
| Cart recovery | ✅ | `POST /coupons` | No | No |
| Post-purchase offer | ✅ | `POST /coupons` | No | No |
| Coupon issue | ✅ | `POST /coupons` | No | No |
| Store credit | ✅ | `POST /coupons` (fixed) | No (credit) | No |
| Address update | ✅ | `PUT /orders/{id}` | No | No |
| Product sync | ✅ | `POST/PUT /products` | No | No (pushes price/SKU) |
| Case / escalation | ✅ | — | No | No |
| Web engagement | ✅ | — | No | No |
| Churn / win-back | ✅ | — | No | No |

All Woo calls go through the **`WooCommerce` Named Credential** (`callout:WooCommerce/wp-json/wc/v3/...`).

---

## Appendix A — The fastest mental model

If you remember nothing else:

- **WooCommerce → Salesforce** via webhooks (fast) + a 15-minute pull (reliable), all through `WooOrderService.ingestOrder`.
- **Salesforce CRM** holds the nouns; **custom objects** add carts, journey memory, web events, training data.
- **The Apex service layer is the brain** — agents call it for every real decision; the AI only phrases the result.
- **Data Cloud** unifies the customer (stream → DLO → DMO → Identity Resolution → unified profile → Calculated Insights) and the agents read a cached copy on the Account.
- **Agentforce** = one web concierge that shops *and* services, sharing one journey + one verified identity, with specialist topics.
- **Messaging for Web** carries the chat; a routing Flow hands it to the agent; the only trusted identity is the server-rendered `loggedInEmail`.
- **Web engagement** is captured by a custom REST endpoint and stitched to people.
- **Einstein Studio** trains a real churn model on point-in-time snapshots; a predict job scores customers; scores are written back to the Account.
- **The win-back engine** turns high-value at-risk customers into a campaign + consent-gated emails, daily.
- **Two safety rails everywhere:** identity-gate personal data, consent-gate outreach.

## Appendix B — Where to click for each piece

| Layer | Salesforce Setup location |
|---|---|
| Objects & fields | Setup → Object Manager |
| Custom metadata (discounts) | Setup → Custom Metadata Types → Discount Rule |
| Apex classes | Setup → Apex Classes |
| Flows | Setup → Flows |
| Scheduled jobs | Setup → Scheduled Jobs |
| Permission sets | Setup → Permission Sets |
| Named credential | Setup → Named Credentials |
| CORS / CSP | Setup → Security → CORS / CSP Trusted Sites |
| Agents | Setup → Agentforce → Agents |
| Web chat deployment | Setup → Embedded Service Deployments |
| Messaging channel | Setup → Messaging → Messaging Channels |
| Omni-Channel routing/queues | Setup → Omni-Channel |
| Public site | Setup → Sites |
| Data streams / mapping / IR / CIs | Data Cloud app → Data Streams / Data Mapping / Identity Resolution / Calculated Insights |
| Einstein model + predict jobs | Data Cloud → AI Models → (model) → Integrations |
| Campaign | Campaigns (Classic) → DC - High-Value At-Risk Win-Back |

---

*This document reflects the system as actually built and verified on the AgentforceDev org. Real API names are used throughout; the deeper gotchas live in the `salesforce-agentforce` skill (`data-cloud.md`, `predictive-and-engagement.md`, `messaging-web.md`, `troubleshooting.md`).*
