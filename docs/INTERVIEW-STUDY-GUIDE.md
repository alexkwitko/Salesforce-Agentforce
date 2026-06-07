# Data Cloud + Agentforce — Consultant Interview Study Guide
### Built from a real end-to-end project: "Kwitko Coffee Co." (WooCommerce → Salesforce → Data Cloud → Agentforce)

**How to use this document.** Read Part 0 and Part 8 first (the story + the Q&A). Parts 3–6 are the deep technical reference — the parts an interviewer probes when they want to know if you have actually *done* this, not just watched a webinar. Every claim here is from a system that is live and tested, so you can speak in the first person: "I configured…", "I mapped…", "I debugged…".

---

## Part 0 — The 60-second story (say this when they ask "tell me about a project")

> I built an autonomous commerce-personalization stack for a coffee retailer running on WooCommerce. Orders, customers, products and cart events flow into Salesforce CRM, then into **Data Cloud**, where I built a **unified customer profile** through **Identity Resolution**. On top of that I built **five Agentforce agents** — an inside-sales agent for abandoned carts, a post-purchase growth agent, a product-advisor, and a customer-facing **website chat concierge** that orchestrates the others. The agents call **Apex invocable actions** and **Flows** to do real work: look a customer up, read their saved preferences from both the Person Account and the unified profile, run a deterministic recommendation engine, issue a real single-use WooCommerce coupon, and hand back a working add-to-cart link. Everything is consent-gated and anti-hallucination guard-railed, and I track coupon redemption and recommendation→purchase conversion so the business can measure efficiency. I built it almost entirely with **Salesforce DX / the `sf` CLI and metadata**, not click-ops, so it's all source-controlled.

That paragraph hits: Data Cloud, Identity Resolution, Agentforce, multi-agent orchestration, actions (Apex + Flow), grounding, consent/governance, analytics, and pro-code delivery. Memorize the shape of it.

---

## Part 1 — Architecture at a glance

**Two business flows, branching at the cart:**

1. **Abandoned (no purchase):** cart inactive 1h with no order → if the shopper is *not* a known unified customer, create a **Lead** → **Inside Sales agent** sends a recovery offer.
2. **Purchased:** order ingested → identity reconcile (dedupe returning customer) → upsert **Person Account** → create **Order/OrderItem** → **Post-Purchase Growth agent** analyzes the basket and sends a 30-day buy-again offer.
3. **Live website chat (always-on):** the storefront chat widget routes to the **Concierge** agent, which recognizes the shopper, checks preferences, recommends, coupons, and builds the cart link in real time.

**The data pipeline (left to right):**

```
WooCommerce (store of record for the cart & checkout)
   │  REST API + webhooks + scheduled pull
   ▼
Salesforce CRM  (Person Account, Order, OrderItem, Product2, Lead, Cart__c, Customer_Journey__c)
   │  CRM Data Cloud connector (streams)
   ▼
Data Cloud  ──Data Lake Objects (DLO)──► Data Model Objects (DMO)──► Identity Resolution ──► Unified Individual
   │                                          │
   │                                          └─► Calculated Insights (LTV / demographics)
   ▼
Agentforce agents  ── actions (Apex invocable + Flow) ──► do real work, ground answers on CRM + Data Cloud + Data Library
```

**Catalog direction is reversed:** Salesforce is the **system of record for products/pricing**; it pushes to WooCommerce. Everything else (orders, customers, carts) flows Woo → Salesforce.

---

## Part 2 — Salesforce platform foundations (own this vocabulary)

| Concept | What it is | Why it matters here |
|---|---|---|
| **Person Account** | A single record representing a B2C individual (Account + Contact fused). Irreversible org switch. | Our customer model. Dedupe by `PersonEmail`. |
| **Standard objects** | Order, OrderItem, Product2, Pricebook2, PricebookEntry, Lead, Account, Contact. | The commerce backbone. **No PricebookEntry = no order line** — the price chain is mandatory. |
| **Custom objects** | `Cart__c`, `Cart_Item__c`, `Customer_Journey__c`, `Agent_Interaction__c`, `Order_Analytics__c`, `Coupon__c`. | Cart capture, agent memory, denormalized analytics. |
| **Permission Set** | Grants object CRUD, field-level security (FLS), Apex class access, external-credential access. | **Gotcha:** a metadata-deployed custom field is invisible (SOQL "No such column") until a permission set grants FLS. |
| **Named Credential + External Credential** | Stores the endpoint + auth so Apex/Flow can call an external API without hard-coding secrets. | `callout:WooCommerce/...` for every Woo call. The *user* pastes the key — a consultant never types secrets into code. |
| **Apex `@InvocableMethod`** | Makes an Apex method callable from Flow **and** from an Agentforce action. One invocable per class. | This is how agents "do things." |
| **Record-Triggered Flow** | No-code automation that fires on insert/update. Async path required for callouts. | Orchestration glue (e.g. abandoned cart → Lead). |
| **Schedulable / Queueable Apex** | Cron-scheduled batch (Schedulable) that enqueues async callout-allowed work (Queueable). | The reliable "sweep" pattern that makes the agents headless. |

**The single most important platform lesson** (and a great interview answer): *automation that is triggered by an external webhook runs as the locked-down Salesforce Site Guest User.* That guest cannot see most records and cannot safely do credential callouts. The fix is to **not** do the work in the guest-context Flow — instead a **Schedulable sweep running as an admin** picks up the new records and does the privileged work. (More in Part 7.)

---

## Part 3 — Data Cloud deep dive

### 3.1 The layered model (the vocabulary is 80% of the battle)

Data Cloud is a lakehouse with a semantic layer on top. The layers, bottom to top:

1. **Data Stream** — a *connection + ingestion job* from a source (Salesforce CRM, S3, ingestion API, web/mobile SDK, Marketing Cloud, etc.). It defines what comes in and on what schedule.
2. **Data Lake Object (DLO)** — the *raw landed table* for that stream, in Data Cloud's internal storage. One stream → one DLO. Named `*__dll`. This is the "data lake."
3. **Data Model Object (DMO)** — the *harmonized, canonical table* in the **Customer 360 Data Model**. Named `*__dlm`. You **map** DLO fields onto DMO fields. DMOs are what segments, insights, identity resolution, and agents actually consume.
4. **Identity Resolution** — match + reconciliation rules that collapse many source rows into one **Unified Individual** ("the unified profile").
5. **Insights** — **Calculated Insights** (scheduled SQL aggregations, e.g. LTV) and Streaming Insights (real-time metrics).
6. **Activation / Data Actions / Segmentation** — push audiences and events back out (to Marketing Cloud, ads, or — via Data Actions/Platform Events — to trigger Flows/agents).

> **Mental hook:** DLO = *raw copy of the source*. DMO = *the shared canonical shape everything agrees on*. Mapping = the translation between them.

### 3.2 The data streams + the data lake — what we ingest and every field

Source connector used: **Salesforce CRM** (zero-copy-ish streaming from CRM objects). Five CRM data streams were created and are ingesting into five active DLOs:

| Data Stream | Category | DLO | Purpose |
|---|---|---|---|
| **Account_Home** | Profile | `Account_Home__dll` | The customer (Person Account) — feeds the unified Individual. |
| **Lead_Home** | Profile | `Lead_Home__dll` | Prospects from cart abandonment. |
| **Order_Home** | Other (engagement) | `Order_Home__dll` | Purchase headers. |
| **OrderItem_Home** | Other | `OrderItem_Home__dll` | Line items (basket detail). |
| **Product2_Home** | Other | `Product2_Home__dll` | Catalog incl. stock, so recs exclude out-of-stock. |
| **Order_Analytics_c_Home** | Other | `Order_Analytics_c_Home__dll` | Denormalized analytics object purpose-built for the Calculated Insight. |

**Stream categories matter:** in Data Cloud every stream is typed as **Profile** (who — maps to Individual), **Engagement** (what happened, time-series — maps to events), or **Other** (lookups/reference). The category drives which DMOs are valid mapping targets and whether the data participates in time-aware features.

**Fields we track on the customer (the ones I added + the standard ones we map):**

- *Account (Person Account):* `PersonEmail` (identity key), `FirstName`, `LastName`, `Phone`, `Woo_Customer_Id__c`, `Customer_Status__c` (Customer vs prospect — the buyer indicator), `Email_Consent__c`, `Email_Consent_Date__c`, `Coffee_Preferences__c` (the JSON preference blob), `Gender__c`, `PersonBirthdate`.
- *Coffee preferences JSON shape* (the durable personalization record): `{ likes[], dislikes[], beanType, brew, roast, format, caffeine, flavored, notes }` — each an **independent axis** (more in Part 4/6).
- *Product2 (catalog + the structured coffee axes I built):* `Woo_Product_Id__c`, `Stock_On_Hand__c`, `Family`, `Image_URL__c`, and the new attribute axes **`Roast_Level__c`** (Light/Medium/Dark), **`Bean_Type__c`** (Single-Origin/Blend), **`Brew_Style__c`** (Espresso/Cold Brew/All-Purpose), **`Is_Decaf__c`**, **`Is_Flavored__c`**.
- *Order / OrderItem:* `Woo_Order_Id__c`, `Source__c`, `Coupon_Code__c`, `TotalAmount`, line `Product2Id`/`Quantity`/`UnitPrice`.
- *Customer_Journey__c (agent memory):* `Email__c`, `Account__c`, `Lead__c`, `Recommended_Product_Ids__c`, `Purchased_Product_Ids__c`, `Preferences__c`, `Coupon_Code__c`, plus the coupon-efficiency fields I added: `Coupon_Issued_Date__c`, `Coupon_Discount_Percent__c`, `Coupon_Redeemed__c`, `Coupon_Redeemed_Date__c`, `Coupon_Redeemed_Order_Id__c`, `Coupon_Discount_Amount__c`.

### 3.3 "Is there one DMO per Data Cloud that all data lakes map into?" — the precise answer

**No — there is one *Data Model* (the Customer 360 model) per data space, made up of *many* DMOs.** You don't map everything into a single object. The right way to say it in an interview:

- A Data Cloud org has one or more **Data Spaces** (tenant partitions; we used the default `default` space). Within a data space there is **one canonical data model** composed of **many DMOs** — Individual, Contact Point Email, Contact Point Phone, Sales Order, Sales Order Product, Product, etc.
- **Many DLOs can map into the same DMO** (e.g. an Account stream *and* a Marketing Cloud contact stream both map onto **Individual**), and **one DLO can map into several DMOs** (our `Account_Home__dll` maps onto **Individual** *and* **Contact Point Email**).
- So the relationship is **many-to-many DLO↔DMO**, not "all lakes into one object." The **Individual DMO** is the *hub* of the profile, but Contact Points, Orders, Products etc. are separate DMOs related to it by keys.

That nuance (one model / many DMOs / many-to-many mapping / Individual is the hub) is exactly what separates someone who's read the docs from someone who's built it.

### 3.4 DLO → DMO mapping — how to actually do it

**Where on screen (Data Cloud app):** open the **Data Stream** (or Data Lake Object) → **Data Mapping** panel → **Start/Review** → **Select Objects** → pick the target DMO(s) → drag a source field's connector dot onto the target field's dot (or use "New Custom Object" to auto-create a DMO that mirrors the DLO and auto-maps every field in one click). Einstein auto-maps obvious fields; you finish the rest by dragging.

**Two real techniques I used and you should mention:**

1. **Auto-create a custom DMO from a DLO:** on the DLO's Data Mapping → Start → Select Objects → Custom Data Model → **New Custom Object** → it creates a DMO with all the DLO's fields + types and auto-maps them. (That's how `Order_Analytics_c_Home__dlm` was built with 24/24 fields in one click.) Source field API names pick up a `_c__c` suffix; the autonumber Name becomes `Name__c`.

2. **Map fields as deployable metadata (the DX way):** DLO→DMO mappings are the **`ObjectSourceTargetMap`** metadata type — fully retrievable/editable/deployable. We have two in source:
   - `Account_Home_map_Individual_…` (Account_Home DLO → **Individual** DMO)
   - `Account_Home_map_ContactPointEmail_…` (Account_Home DLO → **Contact Point Email** DMO)
   Inside, each field link is a `<fieldSourceTargetMaps>` block: `sourceField` = `Account_Home__dll.FirstName__c`, `targetField` = `ssot__Individual__dlm.ssot__FirstName__c`. **Standard DMO fields carry the `ssot__` namespace; custom DMO fields you add do not.**

**A concrete thing I shipped and debugged:** mapping `Account.Coffee_Preferences__c` onto the unified profile. Steps: (a) added the source field to the Account_Home stream via *Add Source Fields*; (b) created a custom `Coffee Preferences` field on the **Individual** DMO (Data Model → Individual → Edit → Add Field); (c) made the source→target mapping. The **metadata deploy** of the new mapping initially failed with `Required field is missing: null` because the just-created DLO/DMO fields hadn't propagated yet, so I completed it in the **mapping canvas** by clicking the source field's connector dot then the target field's dot (a drag registered as a text selection — the two-click connect is the reliable gesture). "Successfully added mappings." **Ingestion is asynchronous**, so the value populates on the next stream refresh, not instantly.

### 3.5 Identity Resolution — how we did it, and "why no semantic rules"

**What Identity Resolution (IR) is:** a published **ruleset** that uses **match rules** to decide which source rows are the same person and **reconciliation rules** to decide which value wins when they disagree, producing one **Unified Individual** with a stable Unified ID.

**Our ruleset — "Coffee Unified Profile":**
- **Primary DMO:** Individual.
- **Match rule "Fuzzy Name and Normalized Email":** `Individual.FirstName` (fuzzy) **AND** `Individual.LastName` (exact) **AND** `ContactPointEmail.EmailAddress` (**Exact – Normalized**).
- Published, with the resolution job set to auto-run.

**The unblock worth telling:** the Individual DMO wasn't even *selectable* as the primary until **Contact Point Email had a relationship to Individual.** I fixed that **via DX** by editing the `ObjectSourceTargetMap` to add the field mapping `PersonIndividualId__c → ssot__ContactPointEmail__dlm.ssot__PartyId__c` and redeploying. That relationship key is what lets IR walk Email → Individual.

**Match types you should be able to rattle off:** Exact, Exact-Normalized (case/format-insensitive), and **Fuzzy** (for names/addresses). Email/phone are normalized contact points; that's why email lives on the **Contact Point Email** DMO, not directly on Individual.

**"Why don't we have semantic rules / reconciliation rules configured?"** Two honest, senior-sounding points:
1. **Email is a hard, unique business key here.** A logged-in e-commerce customer has exactly one email, and the *actual* dedupe that gates account creation happens in CRM (**UPSERT by `PersonEmail` / `Woo_Customer_Id__c` at order ingestion**, backed by CRM Duplicate/Matching Rules). Data Cloud IR's job is the *behavioral* stitch — gluing **anonymous pre-login browsing/cart** (device/session id, no email) to the known customer *after* the email is known — for the 360 view and insights. It is **not** a synchronous gatekeeper, so I didn't need elaborate reconciliation logic to run the business.
2. **Reconciliation rules only earn their keep when multiple sources disagree on the same attribute.** We currently have effectively one authoritative source per attribute (CRM), so the default "most-recent / source-priority" reconciliation is sufficient; adding bespoke rules would be complexity without payoff. (If we added Marketing Cloud or a POS as a second source of `FirstName`/address, *then* I'd add reconciliation rules with a source-priority order.)

That answer shows you understand IR is a *means to a 360*, you know match vs reconciliation, and you make cost/benefit calls — exactly the judgment a practice lead is hired for.

### 3.6 Calculated Insights (CI)

A **Calculated Insight** is scheduled SQL over DMOs that materializes metrics (dimensions + measures) you can use in segments, activations, and agent grounding. Ours: **"Order Patterns by Demographics"** (`Order_Patterns_by_Demographics__cio`), active, every 24h — average order value, total revenue, order count grouped by age group / gender / state.

**Hard-won CI SQL rules (great "I've actually written this" detail):**
- **No table aliases** — reference fields with the full DMO API name every time (`Order_Analytics_c_Home__dlm.Age_Group_c__c`).
- **Output aliases must end in `__c`** (`AS AvgOrderValue__c`).
- **Currency fields must be wrapped** in `TRY_CONVERT_CURRENCY(field, 'USD', 'USD')` inside aggregates; the 3rd arg must be a string literal.
- **A target-currency dimension is required in *both* SELECT and GROUP BY** (`'USD' AS CurrencyCode__c` in SELECT and the literal `'USD'` in GROUP BY).
- DMO **field types are not editable after creation** — fix the type upstream (in the CRM/DLO field) before ingesting if you want to avoid currency machinery.

### 3.7 Segmentation, Activation, Data Actions (concepts to name)

- **Segment:** a filtered population of Unified Individuals (e.g. "VIP buyers in WA who like single-origin"). Built on the DMO + CI layer.
- **Activation:** publishing a segment to a destination (Marketing Cloud, ads, etc.).
- **Data Action / Data Cloud-triggered Flow / Platform Event:** the path to *push* a Data Cloud event back into CRM to trigger automation or an agent. (In our build the agent triggering is done in CRM via Flows/sweeps; Data Actions are the Data-Cloud-native alternative.)
- **Data Kit / Data Space:** packaging and tenant partitioning.

### 3.8 How Data Cloud actually reaches the agents

Three grounding paths, and you should distinguish them:
1. **Synchronous CRM lookup** (fastest, what the live chat uses): an Apex action queries CRM directly (`CustomerLookupService`) for returning-customer status + saved preferences. No Data Cloud round-trip → low latency.
2. **Data Cloud grounding / retrievers:** prompt templates and the **Agentforce Data Library** retrieve DMO records or indexed knowledge to ground answers (RAG).
3. **Calculated Insights as features:** LTV / demographics feed the strategy and segmentation.

The unified profile is the *enrichment/personalization signal*; the *functional* recommendation runs in CRM for latency. Saying that out loud ("I keep the synchronous path in CRM and use Data Cloud for the 360 and insights") demonstrates real architectural judgment about latency vs richness.

---

## Part 4 — Agentforce deep dive (configure the layers, topics, actions — in detail)

### 4.1 The layered architecture (the "Atlas" reasoning stack)

An Agentforce agent is **not** a single prompt. It is a layered system:

```
            ┌─────────────────────────────────────────────┐
User input ─►   ATLAS REASONING ENGINE (the planner)        │
            │   - classifies the utterance to a TOPIC       │
            │   - within the topic, plans which ACTIONS to run│
            └───────────────┬─────────────────────────────┘
                            ▼
   ┌──────────── TOPIC (a job-to-be-done) ───────────────┐
   │  • classification description (when to pick this)    │
   │  • scope + instructions (natural-language guardrails)│
   │  • a set of ACTIONS it's allowed to use              │
   └───────────────┬──────────────────────────────────────┘
                   ▼
   ┌──────────── ACTIONS (the hands) ────────────────────┐
   │  Apex invocable | Flow | Prompt Template | Standard  │
   │  inputs ◄── from the conversation / variables        │
   │  outputs ──► back into the conversation / variables  │
   └───────────────┬──────────────────────────────────────┘
                   ▼
        GROUNDING (CRM records, Data Cloud DMOs/CIs, Data Library RAG)
```

- **Planner / Reasoning engine:** decides *intent → topic → action plan*. You don't code it; you *shape* it with good topic classification descriptions and action descriptions.
- **Topic:** the unit of "what this agent can help with." Metadata type **`GenAiPlugin`**. A **Planner** (`GenAiPlannerBundle`) groups an agent's topics.
- **Action:** the unit of "what it can *do*." Metadata type **`GenAiFunction`** (for classic clicks actions). **In Agent Script, custom Apex actions need no separate GenAiFunction — the runtime auto-discovers the `@InvocableMethod` from `target: "apex://ClassName"`.**
- **Instructions:** natural-language rules at agent and topic level ("always check consent first; never invent a coupon code").
- **Grounding:** the facts the LLM is allowed to use, so it doesn't hallucinate.

### 4.2 Agent types — get this right or you build the wrong thing

| Type | Metadata `Type` | Who uses it | Auth context |
|---|---|---|---|
| **Agentforce (Employee) Agent** | `InternalCopilot` | Internal users (reps, ops) | runs as the user |
| **Agentforce Service Agent** | `ExternalCopilot` | Customers (web/messaging) | runs as a dedicated **EinsteinServiceAgent** bot user |

**Agent Script rule I learned the hard way:** to get an **Employee** agent you must set `agent_type: "AgentforceEmployeeAgent"` and must **omit** `default_agent_user`, `connection messaging:`, and any `@MessagingSession`-linked variables — those make it a **Service** agent. **Agent type is immutable after first publish** — to change it you publish a fresh bundle under a new developer name. Our **website concierge is a Service Agent** (customer-facing); the back-office ones are Employee agents.

### 4.3 Topics — what they are and how to configure them

A **topic** bundles: a **name**, a **classification description** (the sentence the planner matches the user's intent against — *the single most important field for routing accuracy*), **scope**, **instructions**, and the **actions** it may call.

**Configure in Agent Builder (UI):** open the agent → **Topics** tab → **New Topic** (or "Add from Asset Library") → fill **Topic Label**, **Classification Description** ("Use this topic when the customer wants to find or buy coffee…"), **Scope**, **Instructions** (bullet rules), then **Add Actions** to the topic and map each action's inputs/outputs to conversation variables. Test in the **Conversation Preview** pane on the right.

**Configure in Agent Script (pro-code, what we used):** topics are expressed as the agent's **subagents / reasoning structure** inside the `.agent` file. Each "job" gets a block with `actions:` it can use and a `reasoning: instructions:` paragraph. The compiler turns this into `GenAiPlugin` topics + a `GenAiPlannerBundle`. (Our planner bundles in source: `Kwitko_Concierge_Web_v1`, `Inside_Sales_v2`, `Post_Purchase_Growth_v2`, `Product_Advisor_v1`, etc. — one per agent version.)

**Classification tips for the interview:** keep topics **non-overlapping** (overlap → misrouting), write classification descriptions about *user intent* not system internals, and keep an agent's topic count modest. If two topics fight, tighten their descriptions or merge them.

### 4.4 Actions — the five kinds and how to configure each

| Action type | What it is | When to use | How we used it |
|---|---|---|---|
| **Apex action** | An `@InvocableMethod` exposed as an action | Deterministic logic, callouts, DML, anything that must be exact | **All our real work** — lookup, preferences, strategy, coupon, cart link |
| **Flow action** | An autolaunched Flow exposed as an action | No-code orchestration, multi-step record work | Orchestration & product push |
| **Prompt Template action** | A reusable generative prompt with merge fields + grounding | Generate text (email copy, summaries) grounded on records | Email-copy generation pattern |
| **Standard action** | Out-of-the-box (e.g. Knowledge answers, record CRUD, draft email) | Common tasks without code | Available, not central here |
| **API / MuleSoft action** | External call via Flow/External Services/MuleSoft | Call a 3rd-party system | Woo calls go through Apex+Named Credential |

**Anatomy of an action (what you configure):**
- **Reference action label + instructions** ("Issue a real single-use coupon; pass the discount % from the strategy engine").
- **Inputs** — each mapped from a conversation value/variable (e.g. `email`, `discountPercent`).
- **Outputs** — each surfaced back to the conversation (e.g. `couponCode`, `addToCartUrl`), marked *displayable* if the agent may show it.
- **"Require confirmation"** for side-effectful actions if you want a human-in-the-loop checkpoint.

**Configure an Apex action in the UI:** Setup → write the `@InvocableMethod` class → in Agent Builder open the topic → **Add Action → Apex** → pick the class → label it, write the instruction, map inputs/outputs. **Grant the agent (bot) user access to the Apex class via a permission set** or it silently can't run it.

**Configure in Agent Script:** inside a subagent's `actions:` block you declare `name:` with `description`, `target: "apex://ClassName"`, `inputs:` and `outputs:`; then in `reasoning.actions:` you bind it: `build_strategy: @actions.build_strategy with email=…, channel=…` and capture results with `set @variables.x = @outputs.y`.

### 4.5 Instructions & guardrails (governance is a consultant differentiator)

Instructions are natural language but they are *load-bearing*. Ours encode:
- **Consent-first:** the agent must call `check_consent` (Apex `ConsentService`) FIRST and STOP if `hasConsent=false` — before any recommendation/coupon/email. Backed by a hard floor *in the Apex itself* (defense in depth).
- **Anti-hallucination:** "the engine decides products and discount — never invent any"; "never say items are in the cart — they're only added when the shopper clicks the link"; "only ever use the coupon code `issue_coupon` returns."
- **No-loop rejection handling:** on a rejected product, save the dislike, then re-run strategy passing the rejected id in `excludeProductIdsCsv` so it's never re-offered.
- **Check preferences first:** read saved preferences before recommending, honoring each independent axis.

**Three-layer governance** (say this — it sounds senior): (a) **pre-trigger** gate in the Flow (zero LLM cost, non-consenting records never reach the agent), (b) **agent instruction** to call the consent action first, (c) **action floor** — the Apex re-checks consent and aborts regardless. Belt, suspenders, and a second belt.

### 4.6 Agent Script `.agent` file — anatomy

```
config:
  agent_type: "AgentforceEmployeeAgent"   # or omit + add messaging → Service Agent
  ...
agents/subagents:
  <subagent>:                             # ≈ a topic
    actions:
      lookup_customer:
        description: "..."                # the planner reads this to choose the action
        target: "apex://CustomerLookupService"
        inputs:  { email: string ... }
        outputs: { isReturning: boolean, preferences: string ... }
    reasoning:
      instructions: ->
        | CHECK PREFERENCES FIRST: read @outputs.preferences ...
      actions:
        lookup_customer: @actions.lookup_customer
          with email=...
          set @variables.shopper_email = ...
```

**Lifecycle (the CLI flow I used constantly):**
```
sf agent generate agent-spec
sf agent generate authoring-bundle      # creates aiAuthoringBundles/<name>/<name>.agent
# edit the .agent file
sf agent validate                       # compiles the Agent Script (catches errors)
sf agent publish authoring-bundle -n <name>   # → new BotVersion (Inactive) + GenAiPlannerBundle
sf agent activate -n <name> --version N        # activate it
sf agent test create/run                       # AiEvaluationDefinition tests
sf agent preview                               # interactive (needs a TTY)
```
**Publishing creates a *new* BotVersion (Inactive)** — you must **activate** it. (Our concierge is on **v6, Active**.)

### 4.7 Configure an agent in the Builder UI (the screens, end to end)

1. **Setup → Agentforce Studio → Agents → New Agent** → pick a type/template → name + description → choose the **agent user** (Service Agent) and **data/topic library**.
2. **Topics tab** → add topics → for each: classification description, scope, instructions.
3. **Actions** → within a topic, Add Action (Apex/Flow/Prompt/Standard) → map inputs/outputs → set confirmation if needed.
4. **System messages / personality / guardrails** → tone + global instructions.
5. **Conversation Preview** (right pane) → test utterances live, watch which topic + actions fire.
6. **Connections / Channels** → wire the agent to a channel (e.g. Messaging for Web) for customer-facing agents.
7. **Activate**.

### 4.8 Configure via DX (what a pro-code consultant does)

Everything above is metadata: `BotDefinition`, `BotVersion`, `GenAiPlannerBundle` (planner), `GenAiPlugin` (topics), `GenAiFunction` (actions), `AiAuthoringBundle` (the Agent Script), `AiEvaluationDefinition` (tests). Author the `.agent`, `sf agent validate`, `sf agent publish`, `sf agent activate`. Source-controlled, repeatable, promotable across orgs.

### 4.9 Grounding & RAG (so it doesn't make things up)

- **Prompt Templates** with merge fields → ground generated text on specific records (we generate email copy grounded on product flavor notes).
- **Agentforce Data Library / Retrievers** → index knowledge (PDFs, Knowledge articles, DMO records) and retrieve relevant chunks at runtime = **RAG**. We have a `Kwitko_Knowledge_Base.txt` for product/brand grounding.
- **Data Cloud grounding** → ground on DMOs / Calculated Insights for personalization.
- **Action outputs** → the most reliable grounding of all: the agent states facts it got back from an Apex action (a real coupon code, a real product name), never invented.

### 4.10 Multi-agent orchestration (our headline)

The **Concierge** is an **orchestrator** that owns the conversation and delegates to specialist sub-capabilities. Pattern:

- The **Concierge (web)** agent runs the dialog: greet → `lookup_customer` → `check/capture preferences` → `build_strategy` (recommend) → `issue_coupon` → `add_to_cart` → `capture_lead`. It also embeds the **Product Advisor**, **Inside Sales**, and **Post-Purchase** capabilities as topics/subagents.
- **Why orchestration matters:** one front-door agent gives the customer a coherent experience while routing each *job* to the right specialized topic + action set. The **planner** does the routing; **shared memory** (`Customer_Journey__c` via `JourneyService`) keeps state across turns and across agents so nothing repeats (never re-recommend a purchased or rejected item; never double-fire a post-purchase offer).
- **Handoffs:** agent-to-agent (concierge → specialist topic) and agent-to-human (fallback queue via Omni-Channel) are both first-class.

**Three things that make multi-agent work, not just demo:** (1) a **shared memory object** so agents don't contradict each other, (2) **deterministic actions** for anything that must be exact (price, product, discount, coupon), and (3) **idempotency** (sweeps skip already-handled records; coupon issue skips if one exists).

### 4.11 Testing agents

- **`sf agent test`** runs an **`AiEvaluationDefinition`** (YAML test spec): per test case an *utterance*, *expected topic*, *expected actions*, *expected outcome*. We have specs for all agents (`Inside_Sales_Test`, `Post_Purchase_Growth_Test`, `Product_Advisor_Test`, `Kwitko_Concierge_Test`).
- **What's a reliable assertion vs a flaky one:** the **actions** assertion + a **real side effect** (an actual Coupon created, a real Woo coupon id) are the functional truth. The **outcome** assertion is a fuzzy LLM judge. **Topic %** is brittle for Agent Script (the harness reports the router/subagent name, not the topic) — don't over-index on it.
- **Tip:** use a *real, current* record id in the utterance so the run produces a clean outcome with real coupon+email side effects.
- **Apex tests** back every action class (we keep the suite green; today's additions were 8 new tests + 12 existing, all passing).

### 4.12 Our five agents — in full detail

| Agent | Type | Channel | Topics / job | Key actions (→ Apex/Flow) | What it does | Response |
|---|---|---|---|---|---|---|
| **Kwitko_Concierge_Web** | Service (`ExternalCopilot`) | Messaging for Web (storefront) | Orchestrate the whole shopping convo | `lookup_customer`→`CustomerLookupService`; `save_preferences`→`CustomerPreferenceService`; `build_strategy`→`RecommendationStrategyService`; `issue_coupon`→`CouponService`; `add_to_cart`→`CartLinkService`; `capture_lead`→`ChatLeadService` | Recognizes returning shoppers, honors preference axes, recommends, issues a real coupon, returns a working add-to-cart link, captures the lead + transcript | Friendly chat with product, % off, personal code, clickable cart link |
| **Kwitko_Concierge** | Service | (internal/legacy orchestrator) | Orchestrator variant | same family of actions | Orchestrator authoring | — |
| **Product_Advisor** | sub-capability | (within concierge) | Recommend products + quantities | `RecommendationStrategyService`, `ProductSuggestionService` | Picks primary coffee + complementary gear + qty | Structured recommendation |
| **Inside_Sales** | Employee (`InternalCopilot`) | Leads | Abandoned-cart recovery / qualify | `check_consent`→`ConsentService`; recovery→`LeadNurtureService` | Consent-gated cart-recovery offer to a Lead, marks it Working-Contacted | Recovery coupon email |
| **Post_Purchase_Growth** | Employee | Orders/Accounts | 30-day buy-again growth | `check_consent`→`ConsentService`; offer→`PostPurchaseService` | Analyzes the basket, builds a buy-again rec + tiered discount, issues coupon, emails customer | 30-day offer email |

---

## Part 5 — Every action mapped to its Apex/Flow (the "how do I check what each one does" reference)

### 5.1 Apex invocable services (the agent "hands")

| Class | Invocable label | What it does / how | Returns |
|---|---|---|---|
| **CustomerLookupService** | Look up customer | SOQL on Person Account by email → returning status, order history signals, **and the saved `Coffee_Preferences__c`** folded into a summary ("honor these, never recommend disliked items"). Synchronous, CRM-only (low latency). | `isReturning`, `summary`, `preferences` |
| **CustomerPreferenceService** | Save Customer Preferences | Merges a stated preference into the `Coffee_Preferences__c` JSON on the **Person Account** *and* `Customer_Journey__c`. Captures **independent axes**: likes/dislikes, beanType, brew, roast, format, caffeine, flavored. Keeps `dislikes` in sync (e.g. "regular" adds "decaf" to the keyword filter). | merged JSON |
| **RecommendationStrategyService** | Build Recommendation Strategy | The deterministic **strategy brain**: profiles the buyer (New/Recurrent/VIP by LTV+order count), builds an EXCLUDE set (never re-offer purchased/recommended/rejected), picks a **primary coffee** honoring each preference axis as a **hard filter** with **graceful fallback** (relax roast→brew→bean, *never* decaf/flavored, and report what was relaxed), picks a **complementary gear** item by co-purchase affinity, and resolves the discount from the `Discount_Rule__mdt` matrix. **Persists what it recommended** for conversion tracking. | buyerType, primary/complementary product, qty, discount %, `relaxedAxesCsv`, summary |
| **CouponService** | Issue Personalized Coupon | Creates a **real single-use WooCommerce percent coupon** (via `WooCouponService` + Named Credential), code `KW-<NAME>-<PCT>-<RAND>`, records it on the journey with issued date + percent. | `couponCode` |
| **CartLinkService** | Build Add-to-Cart Links | Resolves Salesforce product ids → Woo ids, returns a working `?kc_add=<ids>&kc_coupon=<code>` link (a WPCode storefront handler adds items + applies the coupon). The agent must present the link, never claim items are already added. | `addToCartUrl`, `perItemLinks`, `cartUrl` |
| **ConsentService** | Check Email Consent | Side-effect-free consent check on Order/Lead/Account. The mandatory first action for the outbound agents. | `hasConsent` |
| **ChatLeadService** | Capture Chat Lead | Upserts a Website-Chat Lead (consent + interest + **chat transcript summary**), links the journey. | `leadId` |
| **PostPurchaseService** | (post-purchase offer) | Analyzes an order → recommend → tiered discount → create coupon → email. `without sharing` (trusted back-end). | offer result |
| **LeadNurtureService** | (cart recovery) | Abandoned-cart Lead → 10% recovery coupon + email → mark Working-Contacted. | result |
| **CouponAnalyticsService** | Get Personalization Efficiency Metrics | Aggregates **coupon issued vs redeemed rate**, total discount given, and **recommended→purchased conversion** across journeys. | metrics + summary |
| **JourneyService / JourneyLogger** | Get/Log Journey | The agent **memory**: one `Customer_Journey__c` per email + an append-only `Agent_Interaction__c` log. Tracks recommended/purchased ids, post-purchase-done order ids, coupon lifecycle. | journey state |
| **EmailService** | Send Email (consent-gated) | The single outbound email action; re-checks consent; sends from a verified Org-Wide Email Address. | success |
| **WooOrderService / WooOrderPull / WooWebhookResource** | (ingestion) | Webhook + scheduled pull → upsert Person Account, Order, OrderItems; parses checkout consent; **marks the coupon redeemed** (reads `coupon_lines` + `discount_total`) — closing the efficiency loop. | order id |
| **WooCouponService / WooProductSync** | (outbound) | Push coupons/products to Woo via Named Credential. | woo id |
| **CoffeeAttributeBackfill** | (one-time/util) | Derives the structured coffee axes (roast/bean/brew/decaf/flavored) from Family+Name across the catalog. | summary |
| **Sweeps:** PostPurchaseSweep, CartRecoverySweep, Chat_Nurture_Sweep, PostPurchaseAutoOffer | Schedulable→Queueable | The **headless** engine: run as an admin, find eligible records, enqueue callout-allowed work. | — |

### 5.2 Flows

| Flow | Type | What it does |
|---|---|---|
| **Abandoned_Cart_to_Lead** | Record-Triggered on `Cart__c` (after save, Status=Abandoned & no Lead/Customer) | → `AbandonedCartService` (dedupe: known account → link cart no lead; else create Lead). |
| **Auto_Post_Purchase_Offer** | Record-Triggered on Order (**deactivated** — guest-context lesson) | superseded by the `PostPurchaseSweep`. |
| **Auto_Invoke_PostPurchase_Agent** | Record-Triggered | invokes the post-purchase path. |
| **Sync_Product_to_WooCommerce** | Record-Triggered on Product2 (async, HTTP Callout via External Service) | PUTs catalog changes to Woo `/products/{id}`; stamps sync status. (Pure-Flow, no Apex.) |
| **Kwitko_Web_Chat_Routing** | **Omni-Channel Flow** (RoutingFlow) | Route Work → Agentforce Service Agent (Concierge) with a fallback queue — this is what makes the live chat reach the agent. |

### 5.3 "How do I check what each agent action is doing?" — the debugging playbook

1. **Which action ran?** Agent Builder **Conversation Preview** shows the planner's chosen topic + actions per turn. Headless: **`sf agent test run`** asserts the `expectedActions` list.
2. **Is it a Flow or Apex?** In the topic's action list each action shows its **type + target** (Flow API name or `apex://Class`). In source: the `.agent` `actions:` block `target:`.
3. **What did the action do?** For Apex, read the class (Part 5.1) and check **debug logs** (`sf apex log tail`) or run it in **anonymous Apex** (`sf apex run`). For Flows, open the Flow + its **interview/debug logs**.
4. **What did it return?** The action's **outputs**; the agent surfaces `is_displayable` outputs. `Agent_Interaction__c` logs the result of each step for an audit trail.
5. **Why did it pick that topic?** Tune the **classification description**; check for overlapping topics.

---

## Part 6 — The website chat (Messaging for Web → Agentforce), end to end

**The components, in order:**
1. **Messaging Channel** `Kwitko_Web_Chat` (Messaging for Web) — the storefront widget endpoint.
2. **Embedded Service Deployment** — the JS snippet on the WooCommerce site that renders the chat launcher.
3. **Omni-Channel Flow** `Kwitko_Web_Chat_Routing` (RoutingFlow, Active) with a **Route Work** element → **Agentforce Service Agent = Kwitko Concierge Web**, fallback queue **Kwitko Chat Fallback**.
4. **QueueRoutingConfig** "Kwitko Chat Routing" attached to the fallback queue (or the queue won't appear in the Route Work picker).
5. The **Concierge Service Agent** (BotUser = EinsteinServiceAgent) handles the conversation.

**The "Agents are not available" bug (a perfect war story):** I first set the channel's Routing Type directly to "Agentforce Service Agent." That **never created a PendingServiceRouting**, so the MessagingSession sat in `Status=Waiting` with zero agent messages → the widget said *"Agents are not available."* **The fix:** Salesforce requires an **Omni-Channel Flow with a Route Work element** to route to a Service Agent — not direct channel routing. After wiring the Omni-Flow + QueueRoutingConfig, new sessions go `Active` and the Chatbot replies.

**The test trick (no widget needed):** from the storefront console, read the `JWT` from `localStorage["00DXX0000000000_WEB_STORAGE"]`, `POST {scrt2}/iamessage/v1/conversation` with `{conversationId, routingAttributes:{}}` and a Bearer token, open the SSE stream at `/eventrouter/v1/sse`, and read `CONVERSATION_MESSAGE` events from role=Chatbot. Lets you drive the live agent programmatically.

**The personalization in chat (your independent-axis story):** preferences are **orthogonal axes** — *single-origin vs blend*, *espresso vs pour-over*, *decaf vs regular*, *roast*, *flavored*. A coffee can be single-origin **and** espresso roast **and** regular at once. I modeled each as a structured Product2 attribute, backfilled all 30 coffees, and the engine applies each as a **hard filter** with **graceful fallback** (e.g. there's no single-origin espresso in the catalog → it relaxes *brew only*, keeps bean type, and tells the shopper). "No decaf" never gets relaxed.

---

## Part 7 — Lessons learned & issues (these make you sound senior)

1. **Webhook automation runs as the Site Guest User.** External webhooks hit a public Salesforce Site → everything they trigger runs as a locked-down guest who can't see records or do credential callouts. **Fix:** don't do privileged work in the guest Flow; use a **Schedulable sweep running as an admin** that finds new records and enqueues a **Queueable** (callout-allowed) job. This is the #1 reliability pattern.
2. **Conversational agents don't self-fire on data.** Agents respond to a human/utterance. For self-service e-commerce, the offer must be **automation** (sweeps/Flows), not an agent waiting for data.
3. **FLS gotcha:** a metadata-deployed field is invisible (SOQL "No such column") until a permission set grants FLS. Always deploy + assign a permset after adding fields. (Same symptom can be **schema cache lag** right after creating a Data Cloud field — verify via Tooling `FieldDefinition`.)
4. **Long Text fields can't be filtered in SOQL** — scan + filter in memory (hit this in the analytics query).
5. **Schedulable classes block dependent deploys.** "This schedulable class has jobs pending." **Fix:** abort the scheduled jobs, deploy, then reschedule them (fully scriptable via anonymous Apex) — or enable the deployment setting.
6. **DMO field types are immutable after creation**; fix the type upstream. Currency CI SQL needs `TRY_CONVERT_CURRENCY` + a target-currency dimension in SELECT *and* GROUP BY.
7. **Identity Resolution needs the relationship key first** — Individual wasn't selectable until Contact Point Email had a `PartyId` relationship to Individual (fixed via `ObjectSourceTargetMap` DX).
8. **Data Cloud ingestion is async** — mapped values populate on the next refresh; don't promise "instant." Streams auto-refresh on schedule; manual full refresh on big streams can fail under contention while incremental keeps current.
9. **Agent type is immutable after first publish.** Decide Employee vs Service up front; to change, republish under a new developer name.
10. **Publishing ≠ activating.** `sf agent publish` makes an Inactive BotVersion; you must `sf agent activate`.
11. **Pure-Flow callout gotchas:** async path needs the "Is Changed" operator (only on "A record is updated"); bind External Service path params via the **resource picker**, not typed `{!...}` text (typed literal → 404); active flows save as a new version.
12. **Email deliverability is a domain problem.** Salesforce can't DKIM-sign as `gmail.com`, so DMARC drops it. Real fix = a customer-owned domain + verified Org-Wide Email Address + DKIM. (We left a test gmail as-is by choice.)
13. **Apex `JSON` is case-insensitive** — a variable named `json` collides with the `JSON` class. Name it `serialized`.
14. **Substring traps in normalization** — "no decaf" *contains* "decaf"; classify by intent, not substring (caught by a unit test).
15. **Deploys are async** — wait for final "Succeeded," not the first component table.

---

## Part 8 — Interview Q&A cheat sheet (rehearse these out loud)

**Q: Walk me through Data Cloud's object model.**
A: Streams ingest into **DLOs** (raw lake, `__dll`). You **map** DLOs onto **DMOs** (canonical Customer 360 model, `__dlm`). Mapping is **many-to-many** — many DLOs into one DMO, one DLO into several DMOs. **Individual** is the profile hub; emails/phones live on **Contact Point** DMOs. **Identity Resolution** unifies rows into a **Unified Individual**. **Calculated Insights** aggregate over DMOs. Then segmentation/activation/data actions push out.

**Q: Is there one DMO everything maps into?**
A: No — one **data model** per data space made of **many DMOs**; Individual is the hub, not a single catch-all. Many-to-many DLO↔DMO.

**Q: How does Identity Resolution work / what rules did you use?**
A: A published ruleset with **match rules** (Exact / Exact-Normalized / Fuzzy) and **reconciliation rules** (which value wins). Mine: fuzzy FirstName + exact LastName + normalized email (on Contact Point Email). It needed a relationship key from Contact Point Email → Individual. Its real job is stitching anonymous behavior to the known customer; CRM upsert-by-email is the hard dedupe.

**Q: Why no reconciliation/"semantic" rules?**
A: Email is a unique business key and CRM is effectively the single authoritative source per attribute, so default reconciliation suffices; IR here is for the behavioral 360, not a synchronous gatekeeper. I'd add reconciliation rules with source priority the moment a second source (Marketing Cloud/POS) starts disagreeing on attributes.

**Q: How is an Agentforce agent structured?**
A: Planner (Atlas reasoning) → **Topics** (jobs, `GenAiPlugin`) → **Actions** (`GenAiFunction`: Apex/Flow/Prompt/Standard) → **Grounding** (CRM, Data Cloud, Data Library RAG), all governed by natural-language **instructions**. Metadata: BotDefinition/BotVersion + GenAiPlannerBundle + GenAiPlugin + GenAiFunction; or author it as **Agent Script** (.agent) and publish via DX.

**Q: Topics vs Actions?**
A: A **topic** is *what the agent can help with* (classification + scope + instructions + allowed actions). An **action** is *what it can do* (a single Apex/Flow/Prompt/Standard step with inputs/outputs). The planner classifies the utterance to a topic, then plans actions within it.

**Q: How do you stop an agent hallucinating?**
A: Deterministic **Apex actions** for anything exact (product, price, discount, coupon), instructions that forbid invention, **grounding** on action outputs/records, and **confirmation** on side-effectful actions. Our coupon code only ever comes from the action's return.

**Q: How do you do multi-agent orchestration?**
A: A front-door **orchestrator** (Concierge) owns the conversation and routes each job to the right topic/specialist via the planner, with **shared memory** (`Customer_Journey__c`) for cross-turn/cross-agent state, **idempotency** so nothing double-fires, and human handoff via Omni-Channel fallback.

**Q: Apex action vs Flow action — when which?**
A: Apex for callouts/DML/exact logic/bulk; Flow for no-code, admin-maintainable orchestration; Prompt Template for grounded generation; Standard for common tasks. Apex when correctness/latency matters; Flow when business admins must own it.

**Q: How do you test an agent?**
A: `sf agent test` (AiEvaluationDefinition): utterance → expected topic/actions/outcome. Trust the **actions** assertion + a **real side effect**; the outcome is a fuzzy LLM judge; topic% is brittle for Agent Script. Plus Apex unit tests behind every action.

**Q: How does the website chat reach the agent?**
A: Messaging for Web channel → **Omni-Channel Flow with a Route Work** element → Agentforce Service Agent (+ fallback queue with a QueueRoutingConfig). Direct channel routing to a Service Agent doesn't create the routing record — the classic "Agents are not available" bug.

**Q: How do you ground an agent in business data?**
A: Synchronous Apex/SOQL for low-latency facts, Data Cloud DMO/CI grounding for the 360, and a Data Library retriever for RAG over knowledge. Choose by latency vs richness.

**Q: How do you measure if any of this works?**
A: Coupon **issued→redeemed** rate + discount given (synced from Woo `coupon_lines`/`discount_total` at ingestion) and **recommended→purchased conversion** (the engine persists recommendations; ingestion records purchases) — both from `CouponAnalyticsService`.

---

## Part 9 — Glossary / acronyms

- **DLO / DMO** — Data Lake Object (raw, `__dll`) / Data Model Object (canonical, `__dlm`).
- **Unified Individual** — the deduped profile produced by Identity Resolution.
- **IR** — Identity Resolution (match + reconciliation rules).
- **CI** — Calculated Insight (scheduled SQL aggregation over DMOs).
- **Data Space** — tenant partition of Data Cloud; holds one data model.
- **Activation / Data Action** — push a segment/event out of Data Cloud.
- **Atlas Reasoning Engine** — Agentforce's planner that classifies intent → topic → action plan.
- **Topic** (`GenAiPlugin`) — a job-to-be-done grouping of actions + instructions.
- **Action** (`GenAiFunction`) — a single capability (Apex/Flow/Prompt/Standard).
- **Planner** (`GenAiPlannerBundle`) — the bundle of an agent's topics.
- **Agent Script / Authoring Bundle** (`AiAuthoringBundle`, `.agent`) — pro-code DSL for agents.
- **Employee Agent** (`InternalCopilot`) vs **Service Agent** (`ExternalCopilot`).
- **MIAW** — Messaging In-App and Web.
- **Omni-Channel Flow / Route Work** — the routing that connects a channel to a Service Agent.
- **Person Account** — fused Account+Contact for B2C.
- **Named Credential / External Credential** — secure endpoint + auth for callouts.
- **`@InvocableMethod`** — Apex exposed to Flow + Agentforce actions.
- **Grounding / RAG** — feeding the LLM real, retrieved facts so it doesn't hallucinate.
- **Prompt Template** — reusable generative prompt with merge fields + grounding.
- **FLS** — Field-Level Security (granted via permission set).

---

*You built every layer of this — speak in the first person, lead with the architecture, and use the war stories (the guest-user fix, the "Agents are not available" Omni-Flow fix, the Identity Resolution relationship-key unblock, the independent preference axes) as proof you've done the work. Good luck Monday.*
