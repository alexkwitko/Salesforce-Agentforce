---
name: salesforce-service
description: Use when setting up, configuring, or troubleshooting Salesforce Service Cloud — Case management + lifecycle (record types, BusinessProcess/support processes, queues, assignment/escalation/auto-response rules, validation), case intake (Email-to-Case, Web-to-Case), agent productivity (Service Console, Macros, Quick Text, Case Feed), Lightning Knowledge (enablement, data categories, publishing, dynamic SOSL, agent grounding), Omni-Channel routing (queue/skills/external/flow-based, presence, PendingServiceRouting), digital + voice channels (Messaging for Web/MIAW, Enhanced Messaging, Service Cloud Voice / Salesforce Voice, Open CTI), Entitlements/SLAs/Milestones + Service Contracts/Assets/Incident Management/Surveys, Agentforce + Einstein for Service (Service Agent, Case Classification, Work/Case Summaries, Service Replies, NBA, grounding/prompt templates), order-service flows (OrderSummary, ReturnOrder, refunds/cancellations/store credit), service-agent fix tools + traceability, and transcript/Case persistence. DX/CLI-first with exact metadata types, object/field shapes, the metadata-vs-data-vs-UI-only line, and hard-won gotchas. Pairs with the salesforce-agentforce skill for AI-agent authoring mechanics.
---

# Salesforce Service Cloud Playbook

Practical, **DX-first** playbook for standing up Service Cloud — case handling, intake channels, agent productivity, Knowledge, Omni-Channel routing, digital/voice channels, SLAs/entitlements, AI service (Agentforce + Einstein for Service), and the order-service action layer. Drawn from a real commerce-service build; objects map to any domain (a Case ↔ a ticket/claim; an Order ↔ any transaction).

Deep per-domain detail (exact metadata XML shapes, field lists, Apex APIs, doc URLs) lives in **`reference/`** — load the relevant file when you actually build that piece:
- [`reference/case-management.md`](reference/case-management.md) — Case lifecycle, record types/BusinessProcess, rules, queues, case teams, Email-to-Case/Web-to-Case, Service Console, Macros/Quick Text/Case Feed, reporting.
- [`reference/knowledge.md`](reference/knowledge.md) — Lightning Knowledge enablement, data model, data categories, publishing lifecycle, SOQL/SOSL, agent grounding, permissions.
- [`reference/omni-channel-routing.md`](reference/omni-channel-routing.md) — routing models, ServiceChannel/RoutingConfiguration/presence metadata, skills routing, PendingServiceRouting (Apex), Omni-Channel Flow + Route Work.
- [`reference/messaging-and-voice.md`](reference/messaging-and-voice.md) — MIAW/Enhanced Messaging, EmbeddedServiceConfig, conversation objects, pre-chat, JWT user verification, WhatsApp/SMS, Service Cloud Voice / Open CTI.
- [`reference/entitlements-slas-incidents.md`](reference/entitlements-slas-incidents.md) — Entitlements/EntitlementProcess/Milestones, Service Contracts/Assets/Warranty, Incident Management, Service Catalog, Surveys/CSAT, SLA reporting.
- [`reference/agentforce-einstein-service.md`](reference/agentforce-einstein-service.md) — Agentforce Service Agent, Einstein predictive + generative features, grounding/prompt templates, Einstein Bots vs Agentforce, enablement/licensing.

## #0 rule: Official-first, standard objects, no Frankenstein
Use **standard Service objects** — `Case`, `Queue`, `EntitlementProcess`, `ReturnOrder`, `OrderSummary`, Lightning `Knowledge`, `MessagingSession`, `ServiceChannel` — and declarative routing (assignment/escalation rules, Omni-Channel Flow) before any custom object/Apex. Hand-roll only thin Apex glue invoked by Flow/agent when no native path exists, and say why.

## #1 rule: DX/CLI/API first, UI last
`sf project deploy/retrieve`, `sf data`, `sf apex run`, `sf api request rest`, `sf agent`. Many Service features are **enablement-gated** (Lightning Knowledge, Order Management/OrderSummary, Omni-Channel, Entitlements, Messaging, Einstein/Agentforce). When a metadata deploy silently no-ops, that feature likely needs a Setup toggle first. Drive Setup-UI-only steps headlessly via `sf org open --path "<lightning path>" --url-only` (frontdoor auto-auths with the CLI token; no password). `sf org display` redacts the token → prefer `sf api request rest` / Apex session over raw curl.

## #2 rule: know the metadata / data / UI-only line (the biggest time-sink)
Half of "why won't this deploy" is filing something in the wrong bucket. The load-bearing classifications:

| Thing | Bucket | How you ship it |
|---|---|---|
| Support process | **Metadata** — `BusinessProcess` (there is **no** `SupportProcess` type) | deploy |
| Case status/origin/priority values | **Metadata** — `StandardValueSet` (org-global) | deploy |
| Record types, layouts, compact layouts, list views, FlexiPages, console app | **Metadata** | deploy |
| Assignment / Escalation / Auto-Response rules | **Metadata** — one file *per object*, only one rule active | deploy (never partial — overwrites all) |
| Queues | **Metadata** `Queue` — but deploy `queueMembers` empty | deploy + seed members as data |
| Knowledge enablement, Omni, Entitlements, Messaging, Einstein/Agentforce toggles | **Metadata Settings** (`KnowledgeSettings`, `OmniChannelSettings`, `EinsteinGptSettings`, `AgentPlatformSettings`…) — but first activation often UI-gated | deploy (confirm in Setup) |
| **Macros, Quick Text, Case Team Roles + predefined Case Teams, Enhanced Letterhead, Case Comments** | **DATA** (sObjects) — invisible to `package.xml`/change sets | `sf data tree` / Bulk |
| `BusinessHours`, `Holiday`, `Entitlement`, `CaseMilestone`, `ServiceContract`, `Asset` | **DATA / objects** | `sf data` / Apex |
| Agentforce grounding substrate (Data Library, search index, retriever) | **NOT deployable** — recreate per org | `sf agent adl` / UI |
| ML models (Case Classification, Article Recs) | **NOT deployable** — retrain per org | UI build |
| Email-to-Case routing-address verification, the generated email-services address, MIAW deployment publish + install snippet, Data Cloud provisioning, Trust Layer policy | **UI / runtime-only** | Setup |

## #3 rule: AI-action hygiene (anti-hallucination, gating, traceability)
Service actions (the agent's "fix tools": open/resolve case, return, refund, store credit, cancel) must be:
- **Identity-gated** — verify the caller's identity (signed-in JWT / OTP) before reading PII or acting. A typed/hidden-prechat email is **spoofable**; the verified signal is `MessagingEndUser.AuthenticatedEndUserId`.
- **Anti-hallucination** — default `success=false`; flip to `true` only *after* the backend write succeeds, and **re-query** the created record (e.g. `CaseNumber`) before reporting it. Gate confirmation language on an explicit action-output field, never on intent. (Failure mode: "tests green, prod broke" — agent claims success while the backend gate held 0 records.)
- **Idempotent** — dedupe before creating (e.g. check for an existing coupon/case) so retries don't double-act.
- **Callout-before-DML, fail loud** — when an external callout (e.g. WooCommerce) fails, open a *failure Case* for human follow-up rather than silently succeeding.
- **Traceable** — log who/when/why/what-changed on every action (cross-agent journey log) and write back to the Case/Order.
- **Capped & confirmed** — bound AI-issued value (e.g. store credit ≤ $50) and require explicit shopper confirmation for goodwill.

---

## 1. Case management + lifecycle  → [reference/case-management.md](reference/case-management.md)
- **`Case`** is the core record. Configure: record types (e.g. Order Issue, Return, Billing, General), each tied to a **`BusinessProcess`** (the metadata type behind "Support Process") that scopes the `Status` values; `Origin` (Web, Chat, Email), `Priority`. Closed semantics come from the `<closed>true</closed>` flag on the `CaseStatus` `StandardValueSet` value, not the literal text.
- **Queues** (`Queue` metadata = `Group` Type=Queue + `QueueSObject`) for team routing — a queue must list `Case` in `queueSobject` before a case can be owned by it. **Assignment rules** (`AssignmentRules`) auto-route; **escalation rules** (`EscalationRules`, tied to `BusinessHours`) for SLA breaches; **auto-response rules** (`AutoResponseRules`, `senderEmail` must be a verified OWEA). All three: one file per object, only one active rule, deploy overwrites the whole file.
- **Validation rules** to enforce required fields per status (e.g. `Resolution` required to Close) — but **gate them by Origin/RecordType** so agent/chat inserts don't break (a known failure mode).
- Persist context on the Case: `Case.Description` (32k long-text) + child `Task` ("Chat transcript") records, since native `ConversationEntry` is off-platform.
- Productivity (mostly **data**, not metadata): **Macros**, **Quick Text** (`QuickText`), Lightning **email templates** (`EmailTemplate` UiType=SFX), **Case Feed** layout + quick actions. Service Console = `CustomApplication` (uiType Lightning, navType Console) + a `UtilityBar` FlexiPage (metadata-only — can't be built in App Builder).
- Intake: **On-Demand Email-to-Case** (default modern choice) + **Enhanced Email** (`EmailMessage` sObjects); Web-to-Case for throwaway forms only — prefer an Apex `@RestResource`/Screen Flow for real forms. Gotcha: Email Deliverability = "No access" hides `Case.SendEmail` and **fails any layout deploy referencing it**.

## 2. Digital + voice channels (MIAW / Voice)  → [reference/messaging-and-voice.md](reference/messaging-and-voice.md)
- **Messaging for In-App and Web (MIAW)** is the modern web/in-app chat channel: `MessagingChannel` (`messagingChannelType=EmbeddedMessaging`) + `EmbeddedServiceConfig` (+ `BrandingSet`; `EmbeddedServiceBranding` is **legacy-chat only**). Both are metadata-deployable; **publishing the deployment + generating the install snippet is Setup-UI-only**.
- Conversation objects: `MessagingChannel` → `MessagingEndUser` (identity lives **here** — write `ContactId`/`AccountId`/`LeadId`; the session's `EndUser*Id` are read-only mirrors) → `MessagingSession` → `Conversation` → `ConversationEntry` (**off-platform** — never SOQL; use the Conversation Data GET API or Data Cloud).
- **JWT user verification:** RS256/RS512, header `kid`, payload `sub`/`iss`/`exp`; call `setIdentityToken` **inside the `onEmbeddedMessagingReady` listener** (outside → user falls back to Guest); `clearSession()` on logout to prevent PII persistence. **⚠️ Do NOT "Switch to V2"** if you need login verification — v2 removes user verification. Verified signal = `MessagingEndUser.AuthenticatedEndUserId`.
- **Service Cloud Voice → "Salesforce Voice"** (API names unchanged): Amazon Connect (managed), Partner Telephony (BYOT), or BYO-Amazon. `CallCenter` + `ConversationVendorInfo` are the wiring anchors; `VoiceCall` is the record; transcripts are `ConversationEntry`. **Open CTI is maintenance-mode, EOL Feb 28 2028** — build net-new on Voice. Summer '26: Einstein Conversation Insights is now platform-native (Flow/Apex/Prompt-Builder accessible).

## 3. Web chat → live/AI agent routing (Omni-Channel)  → [reference/omni-channel-routing.md](reference/omni-channel-routing.md)
- Web chat does **NOT** bind directly to an Agentforce/Einstein agent — it routes via an **Omni-Channel Flow** (`Flow` with `processType=RoutingFlow`) + a **Route Work** action. "Agents are not available" almost always = routing/presence config, not the agent.
- Enable Omni first (`OmniChannelSettings`; turn on `enableOmniSkillsRouting` from day one — retrofitting is painful). Build order: Settings → `ServiceChannel` (`relatedEntity=MessagingSession`) → `RoutingConfiguration` (metadata type; its backing object is `QueueRoutingConfig`) → `Queue` → `ServicePresenceStatus` → `PresenceUserConfig` → Flow.
- The Route Work action: Routing Type (queue/skills), Service Channel, target (**Bot** picker covers Agentforce agents — only *active* ones show), and **always a Fallback Queue**. Route Work must be the **last** element on its path.
- Pass identity into the agent: in the routing flow **Update Records on the MessagingSession** custom field from the channel/pre-chat param; the agent variable must be **`linked`** to that field (not mutable). Test in a **new** session.
- Skills/attribute routing or full programmatic control = insert `PendingServiceRouting` with `IsReadyForRouting=false`, attach `SkillRequirement`s, then flip to `true`. `AgentWork`/`UserServicePresence` are the runtime assignment/presence objects.

## 4. Lightning Knowledge  → [reference/knowledge.md](reference/knowledge.md)
- **Enable Lightning Knowledge** first (`KnowledgeSettings`: `enableKnowledge` + `enableLightningKnowledge` — **both irreversible**; first activation often UI-gated; `defaultLanguage` is a locale like `en_US`). Classic→Lightning needs the UI Migration Tool.
- Data model: `Knowledge__ka` (master, stable `kA…` id) vs `Knowledge__kav` (version — what you DML; `ka…` id). Article types = record types on the single `Knowledge__kav`. `PublishStatus` is read-only on DML — **never `update PublishStatus`**; transition via `KbManagement.PublishingService` (pass the `KnowledgeArticleId` master id, not the version id; methods aren't bulkified → Queueable/`@future`, watch `MIXED_DML`).
- **Data Categories** (`DataCategoryGroup`): deploy is **destructive full-replace** — always include the complete tree or categories are permanently deleted. Visibility is **Profile-only** (`categoryGroupVisibilities`; no PermissionSet equivalent); no visibility → `WITH DATA CATEGORY` silently returns 0 rows.
- Querying from Apex: bind variables **fail to compile** in static SOQL against `Knowledge__kav`/`KnowledgeArticleVersion` → use `Database.query` / dynamic **SOSL** (`Search.find` for snippets, `Search.query` when the type isn't compile-time bindable). Always filter `PublishStatus` + a single `Language`.
- AI grounding: the agent answers via the **Answer Questions with Knowledge** action over an **Agentforce Data Library** (Data Cloud index + retriever). The library/index/retriever are **not metadata-deployable** — recreate per org via `sf agent adl`; poll until index "Ready"; agent user needs Knowledge FLS Read + "Allow View Knowledge".
- Link articles to cases via `CaseArticle` (create+delete only, idempotent, uses the `kA…` master id).

## 5. Entitlements / SLAs / support operations  → [reference/entitlements-slas-incidents.md](reference/entitlements-slas-incidents.md)
- **SLA engine:** enable Entitlement Management → `MilestoneType` → `EntitlementProcess` (version-suffixed dev-names; use `versionMaster`) → milestones with `timeTriggers` (negative offset = warning, positive = violation; success actions at the milestone level). Milestones only instantiate when a **Case has an `EntitlementId`** whose Entitlement points to the process via `SlaProcessId` — defining the process is not enough. `BusinessHours`/`Holiday`/`Entitlement`/`CaseMilestone` are data/objects, not source metadata. Modern actions = Flow, not legacy Workflow.
- **Service Contracts & Assets** (`ServiceContract`/`ContractLineItem`/`Asset`; warranty objects are Field-Service-gated) source entitlements contractually. **Incident Management** (`Incident`/`Problem`/`CaseRelatedIssue`) for many-cases-one-rootcause. **Service Catalog**, **Surveys/CSAT** (Feedback Management; send on case close via Flow "Send Surveys"), **Service Intelligence** (Data-Cloud-gated).
- SLA reporting: "Cases with Milestones" report type on `CaseMilestone.IsViolated`/`TimeRemainingInMins`; `ReportType`/`Report`/`Dashboard` are deployable.

## 6. AI service: Agentforce + Einstein for Service  → [reference/agentforce-einstein-service.md](reference/agentforce-einstein-service.md)
- **Agentforce Service Agent** (customer-facing, runs as the `EinsteinServiceAgent` user, no logged-in human): runtime = `Bot`+`BotVersion`+`GenAiPlannerBundle` (v64+); design-time source of truth = `AiAuthoringBundle` (Agent Script `.agent`). Attaches to MIAW via Omni-Channel Flow → Route Work; **email is a separate path** (Email-to-Case + Case Assignment to `EinsteinServiceAgent`). Always include the standard **Escalation** topic + an availability-aware Omni flow or handoff dead-ends.
- **Einstein predictive** (no LLM/Data Cloud): Case Classification + Routing, Article Recommendations, Reply Recommendations, Conversation Mining, Next Best Action (`Recommendation`/`RecommendationStrategy`/Flow — fully deployable). **Einstein generative** (Trust Layer; Data Cloud only for RAG): Work/Case Summaries, Service Replies, Search Answers.
- Settings toggles ARE deployable (`EinsteinGptSettings`, `AgentPlatformSettings`, `BotSettings`, `EinsteinAgentSettings`). The agent user needs an **explicit CRUD/FLS permission set** or record creation silently fails. **`sf agent publish` ≠ activate** — `sf agent activate --api-name X --version N` then verify the active version. See the **salesforce-agentforce** skill for authoring mechanics.

## 7. Order-related service (returns / refunds / cancellations)
- **`OrderSummary`** (Order Management — enablement-gated) is the serviceable view of an order; **`ReturnOrder`** + `ReturnOrderLineItem` for RMAs.
- Refunds/cancellations/store-credit/exchange/reship as **Apex service methods** (one `@InvocableMethod` per class) invoked by Flow or an Agentforce action — following the **#3 AI-action hygiene** rules (identity-gated, idempotent, callout-before-DML, traceable, capped/confirmed). Write outcomes back to the Case/Order and the cross-agent journey log.

## 8. Verification
- Create a Case from each Origin → routes to the right queue/owner; escalation fires on SLA; a Case with an Entitlement spawns `CaseMilestone` rows.
- Return/refund/credit/exchange flow updates the Order/OrderSummary + Case, is idempotent on retry, and logs the action; a failed external callout opens a failure Case (no hallucinated success).
- Web chat connects to the agent (not "unavailable"), recognizes a verified signed-in customer (not a spoofed param), grounds answers on Knowledge with citations, escalates to a human via Omni, and persists the transcript to the Case/Task.
- Run multi-turn agent evals (`sf agent test run` / `run-eval`), not just single-turn — turn-dependent over-promises hide from single-turn tests.

## Consolidated build-order cheat sheet (MIAW web chat → Agentforce + SLAs)
1. **Enable (Settings metadata, confirm in Setup):** Knowledge, Omni-Channel, Messaging, Entitlement Mgmt, Einstein (`EinsteinGptSettings`), Agentforce (`AgentPlatformSettings`); provision Data Cloud if RAG grounding.
2. `BusinessHours` (+ `Holiday`) → `ServiceChannel` (`MessagingSession`) → `RoutingConfiguration` → fallback `Queue` → `ServicePresenceStatus` → `PresenceUserConfig`.
3. Case record types + `BusinessProcess` + validation rules (gated) + purpose-built assignment/escalation/auto-response rules.
4. `EntitlementProcess` + `MilestoneType`s; create a default `Entitlement` and auto-stamp `Case.EntitlementId`.
5. Knowledge: articles + data categories + Profile visibility; Agentforce Data Library (per org) + retriever, poll to Ready.
6. Omni-Channel Flow (`RoutingFlow`) with `recordId` input + Route Work → **active** agent, fallback queue; Update MessagingSession identity field.
7. `MessagingChannel` (`sessionHandlerType=Flow`) + `EmbeddedServiceConfig` + `BrandingSet`; **Setup-UI:** publish deployment, copy snippet, parameter mappings, JWT key set.
8. Build/assign/activate agent: `EinsteinServiceAgent` user + CRUD/FLS perm set → `sf agent publish` → **`sf agent activate --version N`** → verify → live E2E test.

## Gotchas (consolidated)
- **Metadata vs data vs UI-only** (rule #2) is the #1 deploy trap — Macros/Quick Text/Case Teams/Case Comments are **data**; `BusinessProcess` ≠ "SupportProcess"; rules are one-file-per-object full-overwrite.
- Lightning Knowledge / Order Management / Omni / Entitlements / Messaging / Einstein / Agentforce are **enablement-gated** — toggle first; metadata deploy alone silent-fails.
- `KnowledgeSettings` enable flags + `enableLightningKnowledge` are **irreversible**; `DataCategoryGroup` deploy is **destructive full-replace**; never `update PublishStatus`.
- Web chat → agent needs **Omni-Channel Flow + Route Work** (Route Work last on its path), an *active* agent, and a fallback queue — not a direct bind.
- Identity: write the `MessagingSession`/`MessagingEndUser` field in the routing flow; agent var must be `linked`; hidden pre-chat is **spoofable** — true verification = JWT/`AuthenticatedEndUserId`; **don't switch MIAW to V2** if you need it.
- SLAs only fire when a **Case has an `EntitlementId`** — an active `EntitlementProcess` with milestones but 0 Entitlements tracks nothing. **And the #1 trap: `Case.EntitlementId` reporting "No such column" in SOQL/describe/Apex is FLS, not a missing field** — the entitlement/SLA fields default to *hidden FLS* even for admins, and Salesforce surfaces an FLS-hidden field as "no such column" (so a stamp class deploys but silently no-ops). It shows in Object Manager but not at runtime. **Test+fix by deploying `fieldPermissions` for `Case.EntitlementId`** (succeeds → it was FLS; assign that perm set to the agent + human users). Only if that deploy errors "field not found" is it truly unprovisioned (then a Setup → Entitlement Settings off→on cycle provisions it). See [reference/entitlements-slas-incidents.md](reference/entitlements-slas-incidents.md).
- **`sf agent adl create --source-type knowledge` is broken in the dev-preview CLI** (errors + leaves a stray SFDRIVE library) — build the Knowledge Data Library via the Setup UI wizard; then wiring "Answer Questions with Knowledge" into a live agent is a republish+activate version change, pointless until the KB has content.
- **Enabling Surveys is a Setup UI toggle** (auto-adds sample `Customer Satisfaction`/NPS surveys + needs an Experience site for emailable links); CSAT-on-close = a record-triggered Flow with **Send Survey Invitation** (Survey Name = the survey **DeveloperName**, Recipient = a **record Id** like `{!$Record.ContactId}`). **Built + active ≠ delivering** — invitations won't generate/send if the org OWEA fails DMARC (a gmail OWEA produces 0 `SurveyInvitation` rows); verify on a live org that closing a case is safe (after-save flow can roll back the close).
- Knowledge Apex: dynamic SOSL/SOQL (binds don't compile); `Search.find` for snippets; pass the `kA…` master id to `PublishingService`/`CaseArticle`.
- AI actions: gate confirmation on backend success (anti-hallucination), gate destructive fix tools (verified identity + perm set), make them idempotent; the agent user needs an explicit CRUD/FLS perm set.
- `sf agent publish` ≠ activate; ML models + Agentforce grounding substrate are **not deployable** (retrain/recreate per org).
- `sf org open --url-only` = headless Setup-UI auth, no password; `sf org display` redacts the token.
