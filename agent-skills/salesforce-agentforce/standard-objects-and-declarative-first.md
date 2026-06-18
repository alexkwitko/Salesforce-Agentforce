# Standard Objects & Declarative-First — research before you build

**Hard rule for every solution and every agent action: STANDARD before custom, DECLARATIVE before code, DX/CLI before UI.**
Before creating a custom object, a custom field, or an Apex class, you MUST first check whether a Salesforce
**standard object** already models the thing, and whether a **Flow** (or other declarative tool) can do the
work instead of Apex. Reinventing `Order`/`Case`/`ReturnOrder` as custom objects, or writing Apex for what a
Record-Triggered Flow does, is a design defect — it loses platform features (reporting, OmniStudio, OMS,
Field Service, sharing, lifecycle) and adds maintenance cost.

> Decision order for ANY data need: **standard object → standard object + custom fields → custom object (last).**
> Decision order for ANY automation: **Flow / declarative → Invocable Apex called BY a Flow → pure Apex (last).**
> Decision order for ANY change: **sf CLI / metadata → Connect/REST API → UI (last).**

## How to research before building (do this every time)
1. Name the business noun (order, return, refund, case, shipment, customer, payment…).
2. Look it up in the **Object Reference** (`developer.salesforce.com/docs/...object_reference`) and the
   **Order Management / Field Service / Service Cloud** object guides — confirm the standard object + its
   real field API names and relationships. Use `context7`/web for current docs; don't guess `__c` names.
3. Inspect the org: `sf sobject list --sobject all`, `sf sobject describe --sobject <Name>` to see what
   standard objects + fields already exist and are populated.
4. Only if nothing fits, add custom fields to the standard object; only if THAT doesn't fit, a custom object.
5. For automation, ask "can a Flow do this?" before writing Apex. If you need Apex, expose it as
   `@InvocableMethod` so a **Flow** orchestrates it (and an agent can call it) — don't bury logic in triggers.

## Standard objects by domain (the ones that matter for commerce + service agents)

### People & identity
- **Account** (Person Accounts for B2C: the person IS an Account + Contact), **Contact**, **Lead**.
- **Individual** — privacy/consent root. **ContactPointEmail / ContactPointPhone / ContactPointAddress** —
  channel-level contact points + consent. Data Cloud unifies to `ssot__Individual__dlm`.
- **User** (internal + community), **Group/Queue** (routing).

### Sales
- **Opportunity**, **OpportunityLineItem**, **Quote**, **QuoteLineItem**, **Contract**, **Order**, **OrderItem**.
- **Product2**, **Pricebook2**, **PricebookEntry**.

### Commerce / Order Management (B2C Commerce + OMS)
- **Order** + **OrderItem** = the customer's purchase intent (predate OMS). For OMS, the live truth is the
  **OrderSummary** + **OrderItemSummary** (what a service agent looks at first: who ordered, status, items).
- **FulfillmentOrder** + **FulfillmentOrderLineItem** — a shippable group (same location/method/recipient).
- **ReturnOrder** + **ReturnOrderLineItem** — returns/repairs (OMS + Field Service).
- **OrderPaymentSummary**, **CreditMemo**, **CreditMemoLine**, **Invoice**, **Refund**, **Payment** — money.
- **Shipment** — physical shipment + tracking. **OrderDeliveryMethod**, **OrderDeliveryGroup**.
- Service agents integrate to OMS via the standard **OrderSummary** relationship on **Case**.

### Service Cloud
- **Case** (+ CaseComment, CaseMilestone), **Entitlement**, **ServiceContract**, **ContractLineItem**,
  **Milestone**, **Solution/Knowledge (KnowledgeArticleVersion)**.
- **Asset** (what the customer owns), **ProductRequest/ProductItem** (Field Service inventory).

### Messaging / chat (MIAW + Agentforce)
- **MessagingChannel**, **MessagingSession** (+ custom fields for prechat params), **MessagingEndUser**,
  **ConversationEntry**, **Conversation**. Omni-Channel: **ServiceChannel**, **PendingServiceRouting**,
  **AgentWork**, **Queue/QueueRoutingConfig**.

### Activities & misc
- **Task**, **Event**, **EmailMessage**, **ContentDocument/ContentVersion** (files), **Attachment** (legacy).

> If you're about to make `My_Order__c`, `Support_Ticket__c`, `Customer__c`, `Shipment_Tracking__c`,
> `Refund__c` — STOP. Order/Case/Account+Contact/Shipment/CreditMemo already exist. Use them + custom fields.
> (Exception: genuinely novel domain data with no standard analogue — e.g. `Chat_Verification__c` for OTP —
> is a legitimate custom object.)

## Declarative-first automation cheat-sheet (Flow over Apex)
| Need | Declarative (preferred) | Apex (only if…) |
|---|---|---|
| React to a record change | Record-Triggered Flow | logic too complex / bulk callouts / >Flow limits |
| Scheduled work | Scheduled Flow / Scheduled-Triggered Flow | heavy batch (Batchable) |
| Multi-step process / approvals | Flow / Approval Process | — |
| Call out + orchestrate | Flow + HTTP Callout action / External Services | bespoke auth, retries, large transforms |
| Agent action | Flow action OR `@InvocableMethod` Apex **called by the agent/Flow** | — |
| Validation | Validation Rule | cross-object/complex rules |
| Roll-up | Roll-Up Summary / Flow | unsupported relationship |
Agent actions: prefer a **Flow** as the action target; when you need Apex, keep it thin + `@InvocableMethod`
so it's callable from Flow AND the agent, and the orchestration stays declarative.

## DX/CLI over UI (reinforced)
Do it in metadata + `sf` CLI wherever possible — objects, fields, Flows, permission sets, agents (`sf agent`),
Data Cloud (Connect API), routing flows, deploys, and smoke tests are all DX-able. Reserve the UI for the
genuinely UI-only steps (see `troubleshooting.md`): creating CRM data streams, attaching a MIAW user-verification
keyset, Person-Account default record type. Always confirm async deploys with `sf project deploy report`.

## Where this plugs into the build pipeline
- **Discovery** (`discovery-intake.md`): for each data need, record the STANDARD object + real API names (research first).
- **Design** (`solution-design-process-outcomes.md`): each capability's action should target a Flow or thin
  invocable Apex over a standard object; justify any custom object/Apex explicitly.
- **Build** (`agentforce-agents.md` / `deploy-cicd.md`): author as metadata, deploy via `sf`, prefer Flows.

## Field & object archetypes that recur (codify these)
A small reusable vocabulary covers most Agentforce data models:
- **External-id link field** — `<Ext>_Id__c` (Text, `externalId=true`) on standard AND custom objects; you *extend* standard objects (Account/Order/Product2) with external keys rather than mirroring the external system. Set `unique=true` only when the source guarantees uniqueness.
- **Identity key** — one `Email`/key field `externalId=true` + `unique=true` ("upsert one journey per entity"). This is what makes declarative dedup/upsert work.
- **Stamp / idempotency field** — nullable DateTime (`Recovery_Sent_At__c`, `Nurture_Last_Run__c`, `Expires_At__c`). A null stamp = "step not done yet"; record-triggered flows filter on `IsNull`; re-arm by clearing it.
- **Append-only log object** — AutoNumber name, `enableActivities=false`, history off ("append-only log of every agent invocation"). Cross-agent traceability = a child log, not field churn.
- **Orchestration-memory object** — one-per-entity, `enableHistory=true`, comma-delimited id-list text fields as cheap "done set" membership shared across agents/sessions.
- **Ephemeral/secret object** (OTP/token) — activities/history/reports/search ALL false, AutoNumber name; store only **hashes** (`Code_Hash__c`, `Token_Hash__c`), an `Attempts__c` counter, and dual expiry (code vs verified-session); designed to be purged.

## `__mdt` config matrix instead of hardcoded rules or prompt prose
Encode tiered/segmented policy as a **Custom Metadata matrix** keyed on N dimensions (e.g. `Segment__c × Channel__c → Percent__c, Min_Basket__c, Adds_Perk__c`). Admins tune it, the agent can't drift from it, and a pure classifier function (`classify(...) → segment`) maps inputs to a row. Far better than `if` branches or numbers in the prompt. (Protected `__mdt` also holds signing secrets — see `integration-and-fulfillment.md`.)

## Record-triggered Flow guard patterns
- **`doesRequireRecordChangedToMeetCriteria=true`** on a create+update flow → fires only when the record **enters** the qualifying state (declarative "is-changed"), preventing re-fire loops while it stays there. Pair with a boolean/stamp the action clears.
- **Entry filter doubles as the idempotency guard** — e.g. `Status=<X>` AND `Lead__c IsNull` AND `Customer__c IsNull`; the flow is just *trigger + guard*, a thin `@InvocableMethod` does the real dedup/branch.
- **Synthesize-a-missing-event**: capture live state via Apex REST → scheduled sweep transitions the state → record-triggered flow reacts (see capture-now/sweep-later in `integration-and-fulfillment.md`).
- **Ship a flow deactivated in source**: `FlowDefinition` with `<activeVersionNumber>0</activeVersionNumber>` (keep an in-transaction agent-invoke flow as Draft while the live path runs on a scheduled sweep).

## Run an agent FROM automation: the `AgentInvoker` Flow bridge
A generic `@InvocableMethod` wrapping the in-org platform action **`generateAiAgentResponse`** lets a record-triggered Flow or scheduled job run an Agentforce agent headlessly — so the agent's own topics/actions do the work instead of a parallel Apex path. Inputs `agentApiName`, `userMessage` (built from a `$Record` formula — the record-id-in-prompt pattern), optional `sessionId` (continue a multi-turn headless session). Returns a `{"type":"Text","value":...}` envelope to **unwrap**; runs **as the running user** (callers must be privileged); **must be stubbed in tests** (`Test.isRunningTest()` — real agents can't run in test context). This is the declarative-first way to make agents event-driven.

## Data-integrity gotchas that coexist with agent writes
- **Validation rules as a backstop UNDER the Apex eligibility layer (defense in depth):** mirror the lifecycle matrix in a VR (`ISCHANGED`+`PRIORVALUE`+`ISPICKVAL` on the custom `*_Status__c`, cross-object `Parent__r.Status__c` checks on children). **Coexistence gotcha:** if a source-of-truth service supersedes a raw field but a VR still reads that raw field, the agent's Apex must **realign the raw field FIRST, in the same transaction**, before the dependent DML — else the VR blocks the agent's own write (e.g. set `Order.Fulfillment_Status__c='Delivered'` before inserting the dependent `ReturnOrder` whose VR requires a delivered order).
- **Person Account write gotcha:** update with a **fresh sObject** (`update new Account(Id=id, Field__c=…)`) — never the queried record — so you don't touch the read-only PA `Name`/`FirstName`/`LastName` fields, which throw on update.
- **A Long Text Area is NOT SOQL-filterable/aggregatable** — to do closed-loop attribution (e.g. recommended-ids ∩ purchased-ids stored as CSV on a journey record), scan rows (`LIMIT 50000`) and intersect **in memory**. Store decision-time CSVs on the record so you can later prove the agent's recommendations drove the outcome.
- **Back-derive structured facets from unstructured text** with a **pure `derive(...)` function (no DML, unit-testable) separated from the bulk `run()` DML pass**, explicit precedence (name overrides category), idempotent re-derivation — so a recommendation engine can filter on independent preference axes instead of one collapsed category.
- **`DeploymentSettings.doesSkipAsyncApexValidation=true`** speeds iterative agent-action deploys by skipping async test validation — a deliberate (slightly risky) lever, not a default.
