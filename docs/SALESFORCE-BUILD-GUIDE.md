# Kwitko Coffee — Salesforce Build Guide & Tutorial

A teaching walkthrough of **everything** built in Salesforce for the WooCommerce → Agentforce
system: the concepts, **why** each choice was made, **where it lives on screen** (Setup paths),
**how to do it with DX/CLI** (the fast way), and the **gotchas** that cost real time.

> Org: **AgentforceDev** (org name *CPQDream*), Developer Edition, Person Accounts + Data Cloud +
> Agentforce enabled. Store: WooCommerce at `deepskyblue-deer-920559.hostingersite.com` ("Kwitko Coffee Co.").

---

## 0. The mental model (read this first)

The system has **two customer journeys**, and almost every component serves one of them:

```
                         ┌─────────────────────────── WooCommerce store ───────────────────────────┐
                         │  catalog · checkout (consent checkbox) · account signup (consent)        │
                         └───────────────┬───────────────────────────────────┬──────────────────────┘
                       order placed       │                                   │   product edited in SF
                                          ▼                                   ▼
   PULL (scheduled) / webhook → WooOrderService → Person Account + Order + OrderItems + consent
                                          │
              ┌───────────────────────────┴────────────────────────────┐
   PURCHASED  ▼                                              ABANDONED   ▼ (no order in 1h)
   PostPurchaseSweep (every 15m, privileged)                CartRecoverySweep (every 30m)
     → consent check → recommend (affinity) → coupon → AI email      → consent check → recovery coupon → AI email
                                          │
                                          ▼  Data Cloud (separate analytics layer)
            data streams → DLOs → DMOs → Identity Resolution (unified profile) + Calculated Insight
```

**The single most important concept:** an *Agentforce agent* is a **conversational AI a human talks to** — it
does **not** run by itself on data changes. Anything "automatic / headless" (every order gets an offer) is
done by **Apex automation** (a scheduled sweep or a Flow), not the agent. Same business logic, two front doors.

**Two-system rule of thumb:**
- **CRM** (standard objects + Apex) = the real-time transactional system + the automation that does work.
- **Data Cloud** = a separate analytics/unification layer (unified customer profile + aggregate insights). It is
  *not* where per-order recommendations run.

---

## 1. Salesforce foundations

### Concepts
- **Org** — your Salesforce instance. **Setup** (the gear ⚙ → Setup) is the admin console.
- **Metadata** — everything in Salesforce (objects, fields, flows, classes, permission sets, layouts) is
  *metadata* and can be represented as XML files and version-controlled. This is what makes "DX" possible.
- **Salesforce DX (`sf` CLI)** — the developer toolchain. You keep metadata as source files in a project and
  `deploy`/`retrieve` them, run Apex/SOQL, run tests, manage agents — all from the terminal. **Always prefer this
  over clicking in the browser**: it's faster, repeatable, and diff-able.

### Where on screen
- Setup: top-right gear ⚙ → **Setup**.
- App switcher (9 dots, top-left) → choose an app (Sales, Data Cloud, Agentforce Studio, …).

### The DX way (what we used constantly)
```bash
sf project deploy start --metadata "ApexClass:Foo" "PermissionSet:Bar"   # push specific metadata
sf project retrieve start --metadata "Layout:Account-Account Layout"      # pull metadata down
sf apex run --file script.apex                                            # run anonymous Apex
sf apex run test --result-format human --wait 10                          # run all Apex tests
sf data query --query "SELECT ... FROM ..."                              # SOQL from the CLI
sf api request rest "/services/data/v62.0/..."                           # raw REST when no command exists
```

### Gotchas
- **Deploys are async** — wait for the final `Succeeded` (`sf project deploy report --use-most-recent`), not the
  first component table.
- **You can't deploy an Apex class while a scheduled job references it.** You'll see *"bypass this error by allowing
  deployments with Apex jobs pending."* Fix: abort the scheduled jobs, deploy, re-schedule (we did this every time
  we changed `PostPurchaseService`, which the sweeps reference).

---

## 2. Security model (the part that silently bites you)

### Concepts
- **Profile** — baseline permissions for a user (one per user).
- **Permission Set** — add-on permissions you assign on top of a profile. Best practice: grant feature access via
  permission sets, not profiles. Ours is **`Kwitko_Integration`**.
- **FLS (Field-Level Security)** — per-field read/edit. **A custom field is invisible to SOQL/UI until a profile or
  permission set grants FLS** — even for an admin. This is the #1 "my field doesn't exist" gotcha.
- **Object permissions** — CRUD per object (+ View All / Modify All for record visibility).
- **Record Types** — variants of an object (e.g., Account has *Business* vs *Person Account* record types).
- **`with sharing` vs `without sharing`** (Apex) — controls whether code respects **record-level sharing** (who can
  see which records). It does **not** control FLS/CRUD. Backend/integration code that must run regardless of the
  triggering user uses **`without sharing`**.

### Where on screen
- Setup → **Permission Sets** → *Kwitko Integration* → Object Settings / Field Permissions / Apex Class Access.
- Setup → **Profiles** → System Administrator → *Record Type Settings* (Person Account RT is assigned here — **not
  via metadata**, see gotcha).

### The DX way
Permission set is a single XML file: `permissionsets/Kwitko_Integration.permissionset-meta.xml`. Adding a field to
it = add `<fieldPermissions>`; adding a class = `<classAccesses>`. Deploy + (first time) assign:
```bash
sf org assign permset --name Kwitko_Integration
```

### Gotchas
- **Metadata-deployed custom fields are invisible until FLS is granted** — always deploy + assign a permission set
  after adding fields, or SOQL returns *"No such column."*
- **Person Account record type can't be assigned via permission set or profile metadata** ("no RecordType named
  Account.PersonAccount found"). Assign it in the **Setup UI**: Profiles → System Administrator → Record Type
  Settings → Accounts → add *Person Account* + set the default. (One of the few genuinely UI-only steps.)
- **Guest users are deliberately locked down.** Code triggered by a public Site (a webhook) runs as the *Site guest
  user*, which can't see most records or use named credentials. This drove a whole architecture decision — see §10.

---

## 3. The data model (Phase 1)

### Concepts
- **Standard objects** we reused: `Account` (as **Person Accounts** = a person modeled as an Account+Contact),
  `Order`, `OrderItem`, `Product2`, `Pricebook2`, `PricebookEntry`, `Lead`.
- **Person Accounts** — enabling them is an **irreversible** org change. Required for B2C (a shopper is one person).
- **Custom objects** (suffix `__c`): `Cart__c`, `Cart_Item__c`, `Coupon__c`, `Order_Analytics__c`.
- **Custom fields** (suffix `__c`): e.g. `Product2.Woo_Product_Id__c`, `Account.Email_Consent__c`,
  `Order.Woo_Order_Id__c`, `Lead.Email_Consent__c`.
- **The Order chain:** `Order → OrderItem → PricebookEntry → Product2 + Pricebook2 + UnitPrice`. **No
  PricebookEntry = no order line** — this is why catalog/price sync is a prerequisite for ingesting orders.

### Where on screen
- Setup → **Object Manager** → (object) → Fields & Relationships / Page Layouts / Record Types.
- Person Accounts: Setup → search **"Person Accounts"** → enable (irreversible).

### The DX way
Objects/fields are XML under `objects/<Object>/fields/<Field>__c.field-meta.xml`. Deploy with
`sf project deploy start --metadata "CustomObject:Cart__c"` etc. We generated these with small Python scripts
(`tools/gen_phase1_metadata.py`) then deployed.

### Gotchas
- Standard **`Product2.Description`** and an `Image_URL__c` weren't populated in SF (they live in WooCommerce). We
  **backfilled** them from Woo via Apex so the AI emails could show product photos + flavor notes (see §9).
- `Order.TotalAmount` is the sum of line items (excludes shipping) — that's why a $84 Woo order shows $79 in SF.

---

## 4. Inbound integration — getting WooCommerce orders INTO Salesforce (Phase 2A)

There are two ways an external system can push data in. We use both; understand the trade-off.

### 4a. Webhook → Apex REST → public Site (the "push" path)

**Concept.** WooCommerce fires a **webhook** (HTTP POST) when an order is created. Salesforce receives it at a
custom **Apex REST endpoint** exposed publicly via a **Salesforce Site**. The body is verified with an **HMAC**
signature (a shared secret hashes the payload so we know it's really WooCommerce).

**The pieces:**
- `WooWebhookResource` — `@RestResource(urlMapping='/woo/order/*')`, validates `X-WC-Webhook-Signature` (HMAC).
- `WooOrderService` — maps the order JSON → upsert Person Account by email + create Order + OrderItems
  (resolved via `Product2.Woo_Product_Id__c → PricebookEntry`). Idempotent on `Woo_Order_Id__c`.
- `Woo_Settings__c` custom setting — holds the webhook secret.
- A **Salesforce Site** ("Woo Webhook") exposes `/services/apexrest/woo/order/` to the **guest user**; the guest
  profile is granted Apex class access + the Person Account record type.

**Where on screen:** Setup → **Sites** (create/raise the public endpoint) → *Public Access Settings* (guest profile
perms). Setup → **Custom Code → Apex Classes** (or just deploy via DX). WooCommerce side: *WooCommerce → Settings →
Advanced → Webhooks*.

**Concepts that surprised us (gotchas):**
- **Apex runs in system mode for CRUD/FLS**, so the guest only needed *Apex class access* + the *Person Account
  record type* — **not** object CRUD — to create records via `WooOrderService`.
- **WooCommerce webhooks deliver via WP-Cron**, which only fires when the site gets traffic. On a quiet store the
  webhook can be **minutes late or not fire at all**. (This caused "I placed an order and saw nothing in Salesforce.")
- **Everything the webhook triggers runs as the locked-down guest user** — see §10 for why that broke automation.

### 4b. Scheduled PULL (the reliable path we added)

**Concept.** Instead of waiting for WooCommerce to push, Salesforce **pulls** recent orders on a schedule and
ingests any it hasn't seen. This runs as a **privileged user** (not guest) and doesn't depend on WP-Cron, so it's
**reliable and bounded-latency**.

- `WooOrderPull` (Schedulable) → enqueues a Queueable → `GET /wp-json/wc/v3/orders?...` → `WooOrderService.ingestOrder`
  for each (idempotent, skips existing). Scheduled every 15 min.

**Gotcha:** `SELECT Id FROM Pricebook2 WHERE IsStandard=true` returns **0 rows in test context** — Salesforce hides
the standard price book from SOQL in tests. Use `Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT…]`.

> **Lesson:** for B2C order sync, a **scheduled pull is more reliable than a webhook** on a low-traffic store.
> Keep the webhook for low-latency when it fires; the pull is the backstop that guarantees ingestion.

---

## 5. Outbound integration — Salesforce calling WooCommerce (Phase 2B)

### Concepts
- **Named Credential** — Salesforce's secure way to call an external API **without putting secrets in code**. You
  reference it as `callout:WooCommerce/...` and Salesforce injects auth. Made of:
  - **External Credential** (the auth scheme, e.g. Basic Auth) + a **Principal** (the actual key/secret).
  - **Named Credential** (the base URL + "generate auth header" toggle).
  - **External Credential Principal Access** granted via a **permission set** to whoever runs the callout.
- **External Service** — registers an external REST API (from its schema) so a **Flow** can call it natively
  (no code).

### Where on screen
- Setup → **Named Credentials** (two tabs: *External Credentials* and *Named Credentials*).
- Setup → **External Services** (register the Woo Products API for Flow).
- Permission set → *External Credential Principal Access* (grant use).

### The DX way / our specifics
- External Credential **WooCommerce** (Basic Auth) + Named Principal **WooApi** (the user pastes the Woo consumer
  key/secret — **the assistant must never type secrets into fields**).
- Named Credential **WooCommerce** → `https://…hostingersite.com`, *Generate Authorization Header* on.
- Apex callouts then just do `req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/coupons')` — auth is automatic.
- We push coupons (`WooCouponService` / `PostPurchaseService`) and products (a **pure-Flow** product sync) this way.

### Gotchas (pure-Flow product sync)
- An **async path** on a record-triggered Flow (required for callouts) only activates with the **"Is Changed"**
  operator, which is only available on the **"A record is updated"** trigger (not "created or updated").
- **The 404 bug:** an External Service path param `{id}` must be bound via the **resource picker** (a pill), not
  typed as literal `{!$Record.Woo_Product_Id__c}` text — typed text doesn't substitute → Woo returns `rest_no_route`.
- Active flows can't be edited in place — **Save As New Version**, then activate.

---

## 6. Data Cloud — the unified profile + analytics layer (Phase 3)

### Concepts (the vocabulary is the hard part)
- **Data Stream** — a pipe that ingests data from a source (we use the **Salesforce CRM connector**) on a schedule.
- **DLO (Data Lake Object)** — raw ingested data (`..._dll`). One per stream.
- **DMO (Data Model Object)** — the harmonized/business model (`..._dlm`). You **map** DLO fields → DMO fields.
  Only **mapped** objects can be used for segmentation/insights.
- **Identity Resolution** — match rules that stitch records into a **Unified Individual** (a single customer profile
  across sources), e.g. match by normalized email.
- **Data Space** — a partition (we use `default`).

### Where on screen (Data Cloud app)
- **Data Streams** (create/refresh), **Data Lake Objects**, **Data Model** (DMOs + mappings), **Identity
  Resolutions**, **Calculated Insights**, **Data Explorer**.
- DLO → DMO mapping: open the **DLO → Data Mapping panel → Start → Select Objects → "New Custom Object"** (Einstein
  auto-creates a DMO with all fields and auto-maps them — one click).

### Our specifics
- 6 CRM data streams (Account, Lead, Order, OrderItem, Product2, Order_Analytics) → DLOs.
- `Account_Home` DLO mapped to **Individual** + **Contact Point Email** DMOs.
- Identity Resolution ruleset **"Coffee Unified Profile"** (match: fuzzy name + normalized email).
- `Order_Analytics__c` → DLO → a custom DMO → feeds the Calculated Insight (§7).

### Gotchas
- **DLO→DMO mappings ARE DX-deployable** as `ObjectSourceTargetMap` metadata (retrieve/edit/deploy). The Individual
  DMO wasn't selectable for Identity Resolution until Contact Point Email had a **relationship** to Individual; we
  fixed it via DX by editing the `ObjectSourceTargetMap` (mapping `PersonIndividualId__c → ssot__PartyId__c`).
- The **Identity Resolution ruleset itself** has a Connect API but the nested match-rule schema is opaque; the
  ruleset was created via the UI (~5 clicks — a justified last resort).
- **DMO field types can't be changed after creation** (the row menu only offers Delete). Pick the type when the DMO
  is auto-created.
- **Streams auto-refresh on a schedule** — you usually **don't need to manually refresh**. Manual **Full Refresh**
  on the large Order/OrderItem streams can fail under contention; the scheduled **incremental** runs succeed and
  keep them current. **Recommendations don't read Data Cloud anyway** (they run in CRM), so stream freshness only
  affects the analytics/insights layer.

---

## 7. Calculated Insights — aggregate analytics in Data Cloud (Phase 4)

### Concept
A **Calculated Insight (CI)** is a scheduled SQL aggregation over DMOs that produces metrics by dimensions — like a
materialized analytics view. Ours: **"Order Patterns by Demographics"** — avg order value / revenue / order count
by **age group × gender × state**.

### Where on screen
Data Cloud → **Calculated Insights → New → Calculated Insight → SQL authoring**. Write SQL, **Check Syntax**, name
it, **Activate**, set a schedule.

### The hard-won SQL rules (these are non-obvious — see `datacloud-calculated-insight-currency.md`)
- **No table aliases** — reference fields by the **full DMO API name** every time
  (`Order_Analytics_c_Home__dlm.Age_Group_c__c`). Aliases throw *"DMO x not listed in factTables."*
- **Output aliases must end in `__c`** (`... AS AvgOrderValue__c`).
- A **Currency** field must be wrapped: `avg(TRY_CONVERT_CURRENCY(amount, 'USD', 'USD'))` — and the **target
  currency must also be a dimension present in BOTH SELECT and GROUP BY** (`'USD' AS CurrencyCode__c`). This combo
  is what finally validated.

### Gotcha
The recommendation engine does **not** use this CI (the CI is demographic analytics, not a product recommender).
Don't conflate "aggregate insight" with "what to recommend to this buyer."

---

## 8. Agentforce agents — the conversational AI (Phases 6/7)

### Concepts
- An **agent** is an AI assistant a **person** chats with (in the Agentforce console or an embedded channel). It
  reasons with an LLM and calls **actions** (Apex) to do work. **It does not self-trigger on data.**
- **Employee/Internal agent** (`BotDefinition.Type = InternalCopilot`) vs **Service agent** (`ExternalCopilot`,
  customer-facing). We need **Employee** agents.
- **Agent Script** (`.agent` files in `aiAuthoringBundles/`) is the DX way to author agents as code: a top-level
  router + **subagents** (topics), each with **actions** that point at Apex (`target: "apex://ClassName"`).

### Where on screen
- **Agentforce Studio** (App switcher → Agentforce Studio) → Agents → builder / **Conversation preview**.
- Setup → **Einstein Bots** must be enabled (agents won't activate otherwise).

### The DX way (what we used — no screen)
```bash
sf agent generate agent-spec                 # interactive spec
sf agent generate authoring-bundle --spec …  # -> aiAuthoringBundles/<name>/<name>.agent
# edit the .agent file …
sf agent validate authoring-bundle --api-name <name>
sf agent publish  authoring-bundle --api-name <name>
sf agent activate --api-name <name>
```
**To get an Employee agent**, the `config:` block MUST have `agent_type: "AgentforceEmployeeAgent"` and MUST NOT have
`default_agent_user`, `connection messaging:`, or `@MessagingSession` variables (those make it a Service agent).
Custom Apex actions need **no GenAiFunction metadata** — the runtime auto-discovers `@InvocableMethod` from the
`apex://` target.

### Our agents
- **`Post_Purchase_Growth`** → action `generate_offer` (`apex://PostPurchaseService`) + `check_consent`
  (`apex://ConsentService`).
- **`Inside_Sales`** → action `send_recovery` (`apex://LeadNurtureService`) + `check_consent`.
- Both have **consent as the FIRST action**: the reasoning instructions say *call `check_consent` first; if no
  consent, STOP and don't run the offer.*

### Gotchas
- **Agent type is immutable after first publish** — to change Service→Employee we published a fresh bundle with a
  new `developer_name` (the old one can't be deleted via metadata; remove via Setup).
- **`sf agent preview` needs a TTY/connected app** — for headless verification use `sf agent test` (below).

---

## 9. Generative AI for the email copy (Einstein Models API)

### Concept
Hybrid design: **code decides the product/coupon (deterministic, never hallucinated); the AI only writes the copy.**
We call **Einstein's built-in LLM from Apex** — native, **no API key**, no external callout:
```apex
aiplatform.ModelsAPI m = new aiplatform.ModelsAPI();
aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
req.modelName = 'sfdc_ai__DefaultGPT4OmniMini';
aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
body.prompt = '...'; req.body = body;
String text = m.createGenerations(req).Code200.generation.generatedText;
```
`PostPurchaseCopy` / `CartRecoveryCopy` ask the AI for a JSON `{headline, pitch}` grounded in the product's real
flavor notes, then **code assembles** the HTML (product photo + AI words + coupon + CTA). Always falls back to
deterministic HTML so the email never fails.

### Gotchas
- The Models API behaves like a **callout** — generate the copy **before any DML** in the transaction (else
  *"uncommitted work pending"*).
- Skip the AI call in test context (`Test.isRunningTest()`) so unit tests stay deterministic + offline.
- The exact Apex type names are version-specific (the body type is `aiplatform.ModelsAPI_GenerationRequest`, not the
  documented `..._Request_body`). Discover unknown types by forcing a compile error (`req.body = 5;` → the error
  names the expected type).

---

## 10. Automation patterns — making it headless (the big lesson)

### The problem
We wanted "every consenting order automatically gets an offer." First attempt: a **record-triggered Flow** on Order
calling the Apex offer. It **failed** with *"List has no rows for assignment to SObject."*

### Why (the lesson)
The order arrives via the **webhook → public Site → guest user**. Everything that transaction triggers — including
the Flow and the Apex it calls — **runs as the locked-down guest user**, which (a) couldn't even *see* the records
(`with sharing`), and (b) can't run the credentialed Woo callout / create coupons / send email.

### The fix (the reliable pattern)
**Decouple** the privileged work from the guest webhook. A **Schedulable sweep runs as a real privileged user**
(whoever schedules it), finds new consenting orders with no offer yet, and enqueues the offer:
- `PostPurchaseSweep` (every 15 min) → `PostPurchaseAutoOffer.Job` (Queueable, `Database.AllowsCallouts`) →
  `PostPurchaseService.buildOffer`.
- `CartRecoverySweep` (every 30 min) → `LeadNurtureService.run`.
- `WooOrderPull` (every 15 min) → reliable ingestion.
- `PostPurchaseService` is **`without sharing`** (trusted backend).

Scheduling (note: the Apex scheduler **doesn't accept comma-lists in the minute field**, so "every 15 min" = four
jobs):
```apex
System.schedule('Kwitko Order Pull 00','0 0 * * * ?',  new WooOrderPull());
System.schedule('Kwitko Post-Purchase Sweep 07','0 7 * * * ?', new PostPurchaseSweep());
// …:15/:30/:45 etc.
```

### Concepts used
- **Queueable** (`Database.AllowsCallouts`) — async Apex that *can* make callouts; runs as the enqueuing user.
- **Schedulable** — cron-scheduled Apex (can't callout directly → it enqueues a Queueable).
- **Idempotency** — `buildOffer` skips orders that already have a coupon; the recovery marks the lead
  *Working-Contacted* — so sweeps never double-fire.

### Why not just an instant Flow?
On this store the webhook runs as guest (can't run privileged work), and a true instant trigger would require
granting the anonymous guest user broad permissions (a security smell Salesforce blocks anyway). The sweep trades a
few minutes of latency for **reliability + correct permissions**. Latency = WooCommerce WP-Cron delay + up to ~15
min sweep. (The agent remains for a *human* to run an offer on demand, instantly.)

---

## 11. Email consent — captured, synced, and enforced everywhere

### Capture (WooCommerce)
- **Checkout** (block checkout, `/checkout-2/`): a marketing-consent checkbox added via a **WPCode PHP snippet**
  using `woocommerce_register_additional_checkout_field` (block checkout's only supported way to add a field). Shown
  to **guests only** — a CSS snippet hides it for logged-in customers (`body.logged-in …`), who consent at sign-up.
- **Account sign-up** (`/my-account-2/`): a checkbox via the classic `woocommerce_register_form` hook (saves
  `marketing_consent` user meta).

### Sync (→ Salesforce)
`WooOrderService.parseConsent()` reads the order meta key `_wc_other/kwitko/marketing_consent` → sets
`Account.Email_Consent__c = true` + `Email_Consent_Date__c`. Never auto-revokes an existing opt-in.

### Enforce (3 layers, strongest first)
1. **Pre-trigger** — sweeps/`ConsentService` only act on consenting records (zero LLM cost for non-consenters).
2. **Agent-first** — the agent's **first action** is `check_consent`; it STOPS if false (never calls the offer).
3. **Action floor** — consent is the **first line** of `PostPurchaseService`/`LeadNurtureService`; aborts before any
   coupon/callout/email even if something calls them directly.

On the Person Account page, consent shows on the **Person Account layout** (deployed via DX).

---

## 12. The recommendation engine (deterministic + AI)

`PostPurchaseService.buildOffer`:
1. **CONSENT GATE** first.
2. Favorite category = the Product `Family` they bought most.
3. **Primary recommendation** = **co-purchase affinity scoped to coffees** ("customers who bought your beans also
   bought *this coffee*"), falling back to category best-seller, then most-stocked coffee. (Primary is always a
   *consumable* you'd rebuy — never gear.)
4. **Complementary** = co-purchase affinity scoped to **gear** (grinder/filters/etc.).
5. Tiered coupon (15%/20%), scoped in WooCommerce to those product(s), one-time, email-locked, 30-day.
6. **AI writes the email**, code assembles it with product photos.

Affinity is computed in **Apex over CRM order history** (fast, real-time per order). We seeded **~373 realistic
orders with patterned baskets** (espresso ↔ machine/grinder/descaler; pour-over ↔ dripper/filters/kettle) so the
co-purchase signal is meaningful. Verified: *Brazil Santos → Classic Espresso Roast (+ Pour-Over Dripper)*.

---

## 13. Cheat-sheet

### Key Setup screen paths
| Task | Setup path |
|---|---|
| Enable Person Accounts | Setup → "Person Accounts" (irreversible) |
| Custom objects/fields | Setup → Object Manager |
| Permission sets / FLS / Apex access | Setup → Permission Sets → Kwitko Integration |
| Person Account record type | Setup → Profiles → System Administrator → Record Type Settings |
| Named/External Credentials | Setup → Named Credentials |
| External Services (for Flow callouts) | Setup → External Services |
| Public webhook endpoint | Setup → Sites + Public Access Settings |
| Einstein Bots (agent prerequisite) | Setup → Einstein Bots |
| Flows | Setup → Flows |
| Scheduled Apex | Setup → Scheduled Jobs / Apex Jobs |
| Data Cloud | App switcher → Data Cloud (Data Streams / Data Model / Identity Resolutions / Calculated Insights) |
| Agents | App switcher → Agentforce Studio |

### Key CLI commands
```bash
sf project deploy start --metadata "ApexClass:Foo"
sf project deploy report --use-most-recent
sf project retrieve start --metadata "Layout:..."
sf apex run --file script.apex
sf apex run test --result-format human --wait 10
sf data query --query "SELECT ..."
sf agent validate|publish authoring-bundle --api-name <name>
sf agent test create --spec specs/<x>.yaml --api-name <x>
sf agent test run --api-name <x> --wait 10
```

### Verification (Phase 9)
- **Apex tests:** `sf apex run test` — 21 tests, 100%.
- **Agent tests:** `AiEvaluationDefinition` via `sf agent test`. The **actions** assertion (which Apex actions the
  agent called) and a real created Coupon are the functional truth; the **outcome** assertion is a fuzzy LLM judge —
  don't over-index on it. The **topic** assertion is brittle for Agent Script (it reports the router name) — we drop
  it from specs.

### The five gotchas that cost the most time
1. Custom field invisible until **FLS** is granted.
2. Standard **price book not returned by SOQL in tests** → `Test.getStandardPricebookId()`.
3. Webhook/Site code runs as the **guest user** → can't run privileged automation → use a **scheduled sweep**.
4. WooCommerce **webhooks deliver via WP-Cron** (unreliable on quiet stores) → add a **scheduled pull**.
5. Data Cloud **CI currency SQL** needs `TRY_CONVERT_CURRENCY` + a target-currency dimension in SELECT *and* GROUP BY.

---
---

# PART II — Conversational Multi-Agent Commerce (Phase 10+)

Part I built a headless WooCommerce↔Salesforce engine with two **employee** agents. Part II turns it into a
**customer-facing, multi-agent system**: a website **chat** that answers questions (RAG), profiles the shopper,
recommends products, adds to cart, captures a consented lead, and — through one shared brain and a persistent
memory — runs post-purchase and recovery without ever repeating itself or double-acting.

> Design source of truth: `docs/CHAT-AGENT-ORCHESTRATION-DESIGN.md`. This Part is the *teaching* version.

## 14. The mental model for multi-agent

- **Orchestrator** (`Kwitko_Concierge`, a customer-facing **Service agent**) is the single front door. On every
  invocation it (1) reads journey **memory**, (2) routes to a specialist, (3) logs what happened.
- **Specialists**: `Knowledge/Q&A` (RAG), `Product_Advisor` (the **strategy brain**), `Inside_Sales` (leads/recovery),
  `Post_Purchase_Growth` (buy-again offers).
- **The "one brain" is Apex, not agent-to-agent chatter.** All agents call the same Apex services
  (`RecommendationStrategyService`, `JourneyService`, `EmailService`, `ConsentService`) so the strategy is identical
  across chat, post-purchase, and recovery — *without* depending on the (beta, possibly external-unsupported)
  native multi-agent runtime.
- **Two ways an agent gets invoked:** a person chatting (Messaging for Web), **or** a record event
  (new order / abandoned cart / chat-no-purchase) → a Flow → `AgentInvoker` → the agent. Headless = automation runs
  the agent's *own* reasoning instead of a parallel code path.

## 15. Running an agent from Flow/Apex — `AgentInvoker` (the key unlock)

**Concept.** Salesforce ships an in-org action `generateAiAgentResponse` that runs any active agent headlessly — no
Connected App / OAuth. We wrapped it so Flows and Apex can call it.

```apex
Invocable.Action a = Invocable.Action.createCustomAction('generateAiAgentResponse', 'Post_Purchase_Growth');
a.setInvocationParameter('userMessage', msg);          // + optional 'sessionId'
Invocable.Action.Result r = a.invoke()[0];
String text = (String) r.getOutputParameters().get('agentResponse');   // a JSON envelope {"type":"Text","value":"…"}
```
- The response is JSON `{"type":"Text","value":"…"}` → `AgentInvoker.unwrap()` pulls `.value`.
- Runs as the **current user** → schedule headless callers as a **privileged user** (same lesson as §10).
- **Gotcha:** invoking an agent generates a *huge* debug log — your `System.debug` gets truncated off the end.
  To see the reply, write it to a record and SOQL it (we used a `Task`).
- **Why it matters:** even if the Summer '26 multi-agent **beta** doesn't support external/Service agents, `AgentInvoker`
  gives us reliable agent-to-agent + headless invocation today.

## 16. Orchestrator memory — idempotency + cross-agent context

**Concept.** Agents are stateless per session; cross-visit memory must live in Salesforce.
- `Customer_Journey__c` (1 per email): `Recommended_Product_Ids__c`, `Purchased_Product_Ids__c`,
  `Post_Purchase_Done_Order_Ids__c`, `Last_Stage__c`, `Last_Agent__c`, `Preferences__c` (JSON).
- `Agent_Interaction__c`: append-only log of every agent action.
- `JourneyService.getJourneyState(email)` = the orchestrator's **first** action; `JourneyLogger.logInteraction(...)`
  after each step; `JourneyService.recordPurchase(...)` is called from `WooOrderService` at ingestion.

**Why.** This is what stops the system **repeating recommendations** and **double-firing** offers: the exclude set =
purchased ∪ already-recommended ∪ this order/cart; an order in `Post_Purchase_Done_Order_Ids__c` is skipped.

## 17. The recommendation / strategy brain (deterministic + AI)

`RecommendationStrategyService.buildStrategy(ctx)` — the heart of it. **The LLM never picks the product, quantity, or
discount.**

1. **Profile** the buyer (CRM today; Data Cloud unified-profile sync later): order count, LTV, favorite category →
   **New / Recurrent / VIP**.
2. **Exclude set** (the "never repeat").
3. **Anchor**: recurrent → their purchased products; new → stated preferences; cart → cart contents.
4. **Deterministic candidates**: co-purchase **affinity** over `OrderItem` (bean primary, gear complement), with
   best-seller / most-stocked fallbacks, filtered to in-stock + active + Woo-synced.
5. **Discount**: read from **`Discount_Rule__mdt`** (buyer type × channel) — *not* a prompt (§27).
6. **AI augmentation**: the agent adds persuasive copy and may propose 1–2 **extras** — but only from the read-only
   `ProductSuggestionService` (real SKUs) so it **cannot hallucinate products**.
7. **Record** recommended ids back to the journey.

Returns a **strategy packet** (`buyerType`, `primary{id,name,qty}`, `complementary`, `discountPercent`, `excluded`,
rationale) that all three channels consume → one consistent strategy.

## 18. The agents — topics, priority & actions

Authoring is the same DX flow as Part I (§8): `sf agent generate authoring-bundle` → edit the `.agent` → `sf agent
validate authoring-bundle` → `sf agent publish authoring-bundle`. Actions are **Apex invocables** referenced as
`target: "apex://ClassName"` (runtime auto-discovers `@InvocableMethod`).

| Agent | Top topic(s) | Key actions (all Apex) |
|---|---|---|
| `Kwitko_Concierge` (Service) | identify_and_capture → route | `JourneyService`, `ChatLeadService`, `CustomerLookupService`, `JourneyLogger`; delegate via `AgentInvoker` |
| `Product_Advisor` (★ brain) | discovery → recommend → manage_cart | `save_preferences`, `RecommendationStrategyService`, `ProductSuggestionService`, cart glue, `JourneyLogger` |
| `Knowledge/Q&A` | answer_with_knowledge | Data Library **retriever** (grounding, not an action) |
| `Inside_Sales` | cart_recovery / chat_nurture | `ConsentService`, `RecommendationStrategyService`, `LeadNurtureService`(coupon), `EmailService` |
| `Post_Purchase_Growth` | post_purchase_offer | `ConsentService`, `RecommendationStrategyService`, `PostPurchaseService`(coupon), `EmailService` |

**Rule:** `get_journey_state` first; `check_consent` before any coupon/email; the **agent writes the email body**,
`EmailService.send_email` (consent-gated) sends it.

## 19. The four flows

1. **Chat shopping:** chat → journey-state → Q&A (RAG) → capture lead+consent → **discovery** (roast/brew/flavor/
   self-gift/budget/qty) → `build_strategy` → show recs+qty → add to cart.
2. **Post-purchase:** new Order → Flow → `AgentInvoker` → Concierge → (skip if order already done) → `build_strategy`
   **excluding purchased** → coupon → agent email → mark order done.
3. **Abandoned cart:** cart → Flow → agent → analyze cart → alternatives+additions → bigger discount if new → recovery email.
4. **Chat-no-purchase nurture:** scheduled sweep finds Website-Chat leads with no order → Inside_Sales `chat_nurture`
   → compelling conversion email.

## 20. Lead lifecycle & field history (all leads, every source)

Because the Person Account is created from the **Order** (not Lead conversion), leads would never close.
`LeadLifecycleService.closeForPurchase(email, accountId, orderId)` — called from `WooOrderService` — finds open leads
by **email** (cart OR chat) and sets `Status='Closed - Converted'`, `Purchase_Closed__c`, links `Converted_Account__c`
/`Converted_Order__c`, `Closed_Date__c`. Status moves through Open → Working-Contacted → Closed; **Field History
Tracking** is ON for Lead (Status, consent, Purchase_Closed) and `Customer_Journey__c` so every move is audited.

## 21. Returning-customer recognition

`CustomerLookupService.lookup(email)` → `{isReturning, customerStatus, orderCount, lifetimeValue, favoriteCategory,
lastOrderDate}`. CRM today; the design's D-2 swaps the body for a **synchronous Data Cloud unified-profile** query
(needs the history path below) without changing callers.

## 22. RAG with Agentforce Data Library (the semantic layer)

**The gap:** Data Cloud had **no semantic layer** — no knowledge content, no embeddings index, no retriever. RAG can't
work without it. **Fix (D-1):** an **Agentforce Data Library** — point it at curated files/Knowledge; it builds the
embeddings **search index** + a **retriever**; ground the Knowledge/Q&A subagent on it.
- **Screen step (S2):** enable Data Library + the embeddings model in Setup; create the library; add content (our 59
  product descriptions + ~10 brewing/policy articles).
- **Anti-hallucination:** instruct "answer only from retrieved sources; if not found, say you don't know."

## 23. Deploying the chat to WooCommerce (Messaging for Web)

**Screen step (S3):** Setup → Messaging → create a **Messaging for Web channel** linked to the Concierge → create an
**Embedded Service deployment** → copy the JS **snippet** → allowlist the Woo domain → paste the snippet into WordPress
via **WPCode** (same tool as the consent snippets). **Cart front-end glue (D-3):** custom JS subscribes to the embedded
messaging events, reads the agent's `add_to_cart` payload, and calls the **Woo Store API** in the browser (the cart is
browser-session bound; the agent is server-side, so the add must run client-side).

## 24. Multi-agent external publishing — the risk we designed around

The Summer '26 Multi-Agent Orchestration is **beta**, and historically agent orchestration didn't work for
Communities/Service agents. So we **don't depend on it**: the Concierge is a normal Service agent that uses **shared
Apex** for strategy and **`AgentInvoker`** for delegation — works today. Native multi-agent is a *verify-in-sandbox*
enhancement, not a go-live dependency.

## 25. Testing — Agentforce Testing Center + Apex + use cases

- **Agent behavior → Agentforce Testing Center** (engine) driven by **`sf agent test`** (`AiEvaluationDefinition`, DX) +
  the Testing Center UI. One set per agent + orchestrator-routing. Assert **actions in order** (journey-state first,
  consent before send) — topic assertions are brittle.
- **Deterministic logic → Apex unit tests** (discount math, exclusion, consent gate, idempotency, lead close).
- **End-to-end → UC1–UC12** (incl. UC5 idempotency, UC8 no-consent, UC11 prompt-injection, UC12 hallucination probe).

## 26. Guardrails & anti-hallucination (layered)

1. **Architectural:** products/quantities/discount/coupons = deterministic Apex → the LLM can't invent them; AI extras
   come from grounded `ProductSuggestionService`; validate any product id before a side effect.
2. **RAG grounding:** answer only from the retriever; no hit → "I don't know."
3. **Per-topic:** off-topic redirect, prompt-injection defense, consent-first, confirm before side-effects.
4. **Einstein Trust Layer:** PII masking, toxicity/prompt-defense, grounding, audit, zero retention.
5. **A2A:** single-hop, capped depth; journey memory blocks loops/duplicates.

## 27. Custom Metadata for tunable rules — `Discount_Rule__mdt`

The discount matrix lives in a **Custom Metadata Type** (buyer type × channel → `Percent__c`, `Adds_Perk__c`,
`Basket_Bump_Percent__c`, `Min_Basket__c`) read by `RecommendationStrategyService`. Tunable in Setup/deploy **without
code** and **never a prompt**.
- **Gotcha (this org):** deploying CMDT *records* via the Metadata API threw an opaque `UNKNOWN_EXCEPTION` (even a
  minimal record). **Workaround:** seed them via the **Apex Metadata API** (`Metadata.Operations.enqueueDeployment`) —
  fully CLI-driven (`sf apex run`). The CMDT *type + fields* deploy fine; only the records needed the Apex path.

## 28. Build checklist — done vs remaining

**Done (DX, deployed + tested):** data model (`Customer_Status__c`, chat-lead fields, `Customer_Journey__c`,
`Agent_Interaction__c`, Lead lifecycle fields + field history); `Discount_Rule__mdt` + 9 records; Apex —
`AgentInvoker`, `JourneyService`/`JourneyLogger`, `RecommendationStrategyService`, `EmailService`,
`LeadLifecycleService`, `CustomerLookupService`, `ChatLeadService`, `ProductSuggestionService`; `WooOrderService` now
sets buyer status, records purchases, and closes leads. All unit tests green.

**Screen progress (done live in Setup):**
- **Agentforce** is **ON** (Einstein Generative AI → Agentforce Studio → Agentforce Agents).
- **S2 Data Library — CREATED:** "Kwitko Knowledge" (`Kwitko_Knowledge`), data type **Files**. The real KB is generated
  at `docs/Kwitko_Knowledge_Base.txt` (60 products + brewing/shipping/returns/subscription/privacy). **One user click
  left:** open the library → Select Files → pick that file → Upload (the file-picker is a native OS dialog that
  automation can't drive safely; the upload tool only accepts session-shared files).
- **S1 Multi-Agent:** there is **no global toggle** — multi-agent is built **per agent in the new Agentforce Builder**
  (add other agents as sub-agents). So it's authoring work, not a switch. Our `AgentInvoker` path needs nothing here.

**Agents BUILT, PUBLISHED & AGENT-TESTED (live, via Agentforce Testing Center):**
- **`Product_Advisor`** — published; test run invoked `build_strategy` + `suggest_products` and returned a real
  recommendation at the correct matrix discount.
- **`Kwitko_Concierge`** (orchestrator) — published; test run invoked **`lookup_customer → capture_lead → build_strategy`**
  and replied *"Welcome back, Jane! …returning customer… 10% off"* — full conversational path proven.
- **Record-triggered Flow** `Auto_Invoke_PostPurchase_Agent` (Order → `AgentInvoker` → `Post_Purchase_Growth`) deployed.
- **`Chat_Nurture_Sweep`** (Flow 4) deployed + scheduled; **`PostPurchaseCopy`/`CartRecoveryCopy` deprecated**.
- **Apex: 36/36 tests green.**

**Remaining (genuinely screen/site-bound — your steps + my snippets):**
- **Data Library file attach:** 1 native-dialog click — Select Files → `docs/Kwitko_Knowledge_Base.txt` → Upload.
- **S3 Messaging for Web** channel + Embedded deployment + WPCode snippet (and make Concierge a Service agent) — channel wizard.
- **Cart front-end glue** (Woo Store API JS on the site) and the **Data Cloud history sync** path for `CustomerLookupService`
  (it runs on CRM today) — site/Data-Cloud work.
- Author/extend agent bundles: add the new Apex actions to `Inside_Sales` + `Post_Purchase_Growth`; create
  `Product_Advisor` + `Kwitko_Concierge` bundles; publish.
- Record-triggered Flows → `AgentInvoker`; `Chat_Nurture_Sweep`; cart front-end glue; Data Cloud history path
  (map Order → DMO + customer-level CI) for the synchronous profile.
- Agent test specs (UC1–UC12) in Testing Center.

## 29. Part II cheat-sheet

**New classes:** AgentInvoker, JourneyService, JourneyLogger, RecommendationStrategyService, EmailService,
LeadLifecycleService, CustomerLookupService, ChatLeadService, ProductSuggestionService (+ tests).
**New objects/CMDT:** Customer_Journey__c, Agent_Interaction__c, Discount_Rule__mdt.
**New commands:**
```bash
# run an agent headlessly (proof)
sf apex run --file invoke_agent.apex
# seed CMDT records when metadata deploy throws UNKNOWN_EXCEPTION
sf apex run --file seed_discount_rules.apex   # Metadata.Operations.enqueueDeployment
# agent tests
sf agent test create --spec spec.yaml --api-name Kwitko_Concierge_Test
sf agent test run --api-name Kwitko_Concierge_Test --wait 10
```
**New gotchas:** (1) only **one `@InvocableMethod` per class** (split JourneyService/JourneyLogger). (2) PermissionSet XSD
requires `objectPermissions` and `fieldPermissions` each **contiguous**. (3) scheduled jobs **lock dependent classes** on
deploy → abort CronTriggers, deploy, reschedule. (4) CMDT **records** → Apex Metadata API. (5) agent invocation **floods
the debug log** → persist the reply to read it.
