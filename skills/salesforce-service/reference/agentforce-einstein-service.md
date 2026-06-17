# Agentforce + Einstein for Service (DX reference)

> Service-specific AI. For agent-authoring mechanics (Agent Script, headless invocation, eval harness), use the **salesforce-agentforce** skill. Current to Summer '26.

**Two framing facts:** (1) **Predictive** features (Case Classification, Article/Reply Recommendations, Conversation Mining, NBA) are classic Einstein ML — **no LLM, no Data Cloud**. **Generative** features (Service Replies, Work/Case Summaries, Search Answers, the Agentforce Service Agent) run on the Atlas Reasoning Engine + Einstein Trust Layer, sold under Agentforce for Service, and need **Data Cloud (Data 360)** for **RAG grounding** but not for base summary/reply. (2) **DX line:** agent metadata, prompt templates, NBA strategies, and the settings toggles ARE deployable; Data Cloud provisioning, Data Library/retriever/index builds, ML model training, channel/email wiring, and Trust Layer policy are UI/back-office.

## PART A — Agentforce Service Agent

### A1. When to use / lineage
Einstein Bots → Einstein Copilot → **Agentforce** (Sept '24). **Two classes:**
- **Agentforce Service Agent** (customer-facing, autonomous, runs **without a logged-in user** on MIAW/SMS/WhatsApp/Email/Voice) — agent user API name **`EinsteinServiceAgent`**, profile Einstein Agent User. **This is the target.**
- **Agentforce (employee/internal) Agent** — in the flow of work for logged-in users.
- ⚠️ **Agentforce (Default)** is frozen / not in new orgs (post-June 2025) → use the Employee agent for internal.

### A2. Metadata model (two generations coexist)
Runtime is **still `Bot` + `BotVersion`**; adding a **`GenAiPlannerBundle`** promotes a bot to an agent.
| Type | Represents | Notes |
|---|---|---|
| `Bot` | top-level agent; `type` distinguishes | same object as Einstein Bots |
| `BotVersion` | version config, welcome/transfer instructions | one active version |
| `GenAiPlannerBundle` | reasoning engine — all subagents + actions (`agentGraph.json` + encoded `agentScript`) | **v64+**; supersedes deprecated `GenAiPlanner` (v60–63); one per agent |
| `GenAiPlugin` | a subagent = a **topic** | many per agent |
| `GenAiPluginInstructionDef` | topic instructions | |
| `GenAiFunction` | an agent **action** (input/output schema) | backed by Apex/Flow/Prompt Template |
| `GenAiPromptTemplate` (+ `…Actv`) | prompt template backing an action | v60+ |
| `AiAuthoringBundle` | **design-time Agent Script** (`.agent` + `.bundle-meta.xml`) — DX source of truth | v65/66; `target` = `{Bot}.{BotVersion}` |

New Builder draft = `AiAuthoringBundle`; on commit/publish the platform translates `.agent` → active `Bot`+`GenAiPlannerBundle`. Bundleized lifecycle needs API v66.

### A3. Channel attachment
- **Messaging (MIAW/SMS/WhatsApp) — indirect:** `MessagingChannel` + `EmbeddedServiceConfig` → an **Omni-Channel Flow** (Route Work, Routing Type = **Bot** → the agent). Same for all enhanced channels. See [messaging-and-voice.md](messaging-and-voice.md) + [omni-channel-routing.md](omni-channel-routing.md).
- **Email — separate path (no Route Work→Bot):** Email-to-Case creates the Case → Setup → **Agentforce for Service on Email** → Email Configuration assigned to the Service Agent → **Case Assignment Rules** (`Origin=Email`) set owner = `EinsteinServiceAgent` → agent processes + replies. **Limitation:** subject + body text only (ignores images/attachments).
- Keep channel metadata in source control as a separate deploy unit; channel provisioning + Omni wiring have heavy Setup-UI deps.

### A4. Grounding (Knowledge + Data Cloud)
RAG via **Agentforce Data Libraries (ADL)** on Data Cloud: source (Knowledge/files/web/custom DMO) → chunk → index → search index + retriever. The **Answer Questions with Knowledge** action (General FAQ topic) invokes the retriever. `sf agent adl` (Dev Preview) / Setup-UI. Agent user needs Knowledge FLS Read + "Allow View Knowledge" + Data Space access. **Gotcha:** index must reach **"Ready"** or the action silently returns nothing. See [knowledge.md](knowledge.md) §7 + PART C below.

### A5. Standard service actions
Answer Questions with Knowledge, Create a Case / Update Record, Get Record Details, Identify Record by Name, Query Records (+ Aggregate), Summarize Record, Draft or Revise Email, Escalation/Transfer. **Extend** = custom `GenAiFunction` backed by Apex/Flow/Prompt Template (your order-service/refund/store-credit pattern).

### A6. Standard service topics (each = a `GenAiPlugin`)
Case Management, Order Management/Inquiries, **General FAQ** (hosts Answer Questions with Knowledge), **Escalation** (handoff; no actions), Account Management, Reservation Management, Delivery Issues. Author net-new topics if none fit.

### A7. Escalation / handoff
The standard **Escalation** topic uniquely has **no actions** — recognizes escalation intent and triggers handoff to the **Omni-Channel Flow** → Check Availability → Route Work to a queue/skill (transcript/context preserved; transfer instructions on `BotVersion`). **Most common dead-end defect:** handoff fails silently if the Escalation topic is missing or the Omni flow has no availability branch (offer callback / leave a message). **Always add the Escalation topic + an availability-aware flow.**

### A8. Anti-hallucination (documented failure mode)
Two modes: **outcome hallucination** (claims done though the action result says otherwise) and **action hallucination** (claims an action that never ran). Mitigations: design `GenAiFunction` outputs to return an explicit **success boolean / record id**, and write instructions that **gate confirmation language on that output field** — never on intent. Deterministic post-conditions (a structural `identity_gate` subagent) outperform prose. Diagnose via the resolved prompt; **verify with multi-turn `sf agent test run` / `run-eval`** (single-turn misses turn-dependent over-promises).

### A9. CLI lifecycle
`sf agent generate agent-spec` → `generate authoring-bundle` / `create` → deploy `AiAuthoringBundle,GenAiPlannerBundle` → **`sf agent publish authoring-bundle --api-name X`** → **`sf agent activate --api-name X --version N`** → `sf agent preview` / `test run` / `run-eval`. **⚠️ `publish` does NOT activate** — published version stays Inactive; activate then verify the active version before testing. Don't wildcard `ApexClass`/`Flow`/`GenAiPromptTemplate` in package.xml; don't hand-edit retrieved bundle XML; committed versions are immutable.

### A10. Summer '26 deltas
Agent-Script email-behavior governance; **Multi-Agent Orchestration** (shared context, Connect Agent as Subagent Beta); Voice Call Routing via SIP; Draft Contextual Case Comments; Find Case Experts; Merge Unopened Duplicate Cases in Omni Queues (Beta); **Agentic Milestones (Beta)** (auto SLA comms); Agentforce Builder default July 13 2026; Agent Script + Agent Preview GA; Agentforce DX MCP Server + Vibe IDE.

## PART B — Einstein for Service

### B1. Case Classification + Case Routing (predictive)
ML on the last 6 months of closed Cases → recommends/auto-populates Case picklist/checkbox/lookup fields at creation; Routing consumes predicted values → Assignment/Skills rules → Omni. **No LLM/Data Cloud.** Enable (UI): Einstein Classification → Case Classification → add fields → resolve warnings (**≥400 closed cases/field**) → Select Best Value (recommend) vs Automate (paid, threshold > Select) → Build → Activate; drop the **Einstein Field Recommendations** component. Flow action `ApplyCaseClassificationRecommendations`. Org settings = **`EinsteinAgentSettings`** (governs Classification + Wrap-Up). **Models are UI-only — not deployable; retrain per org.** Gotchas: picklist/checkbox/lookup only; Case Wrap-Up is recommend-only regardless of license.

### B2. Work Summaries (Case Wrap-Up) + Case Summaries (generative)
Work Summaries = generative summary of a **conversation** (Messaging/Chat/Voice/Email + mid-chat Catch-Up) → drafts Summary/Issue/Resolution via **Einstein Field Recommendations** (Recommendation Type = **Wrap-Up**). Case Summaries = summary of a whole **Case** via the OOB "Summarize Case" prompt template. Enable: Einstein Work Summaries + per-channel tabs; **target fields must be Text Area / Text Area (Long)** or output won't store. Runs on Trust Layer over Service Cloud data — **no Data Cloud** for base. Prompt templates = `GenAiPromptTemplate` (referenced custom fields must pre-exist); toggles + mapping UI-only. Gotcha: Recommendation Type must = Wrap-Up or you silently get legacy predictive behavior.

### B3. Reply Recommendations (curated) vs Service Replies (generative)
- **Reply Recommendations** = ML over ~1,000+ historical transcripts → suggests published canned replies. No LLM.
- **Service Replies** = generative drafting for chat/messaging **and email**, grounded on Knowledge + Case via **Service AI Grounding** — no training. Summer '26 **KGER** drafts from up to 3 articles. Enable: Reply Recommendations → Service Replies On → Service AI Grounding On (map Knowledge Title/Summary/Answer + Case fields) → Knowledge Share via Public URLs (citations) → `Service Replies User` → Einstein Replies component. Grounds on native Knowledge+Case — **no Data Cloud** for the standard path.

### B4. Article Recommendations / Search Answers / Knowledge grounding (three distinct)
| Feature | Mechanism | Data Cloud |
|---|---|---|
| Einstein Article Recommendations | supervised ML on past case↔article links → ranked articles in case feed | No |
| Reply Recommendations | ML over transcripts → canned reply text | No |
| Search Answers / Answers from Knowledge | generative RAG over Knowledge with citations | Classic search = No; **Agent RAG / Enterprise Knowledge (Data 360) = Yes** |

Article Recs: select case + article fields → Build (~48h) → Activate; needs Lightning Knowledge + ~1,000 closed cases + 100+ articles; no add-on. Search Answers: Einstein Search toggles (rides the standard index — no Data Cloud); generative grounding via Prompt Builder "Answer Questions with Knowledge" + Data Library **requires Data Cloud**. "Knowledge powered by Data 360" (GA Apr 2026) requires Data Cloud.

### B5. Einstein Conversation Mining (ECM)
Unsupervised mining of **service transcripts** → top contact reasons/intents → seeds bot/agent utterances. **NOT** Einstein Conversation *Insights* (ECI = sales-call coaching). Build async (~24h); gate = **≥2,500 conversations** with an identifiable contact reason; English only; Email-to-Case analyzes only the first inbound email; Enhanced Conversations reports unavailable in Sandbox. Reports = UI; downstream Bot dialogs/topics deployable. Data Cloud not required.

### B6. Next Best Action (most DX-friendly)
Surfaces context-aware offers/actions on a record page (refund vs store-credit vs escalate). **Fully deployable:** `Recommendation` object (`ActionReference` = Flow/action on accept, `AcceptanceLabel`), `RecommendationStrategy` metadata (legacy Strategy Builder), or a **Flow of type "Recommendation Strategy"** (2026 direction — 450+ actions, Agentforce integration). Surface = Einstein Next Best Action component (`FlexiPage`). No add-on / no Data Cloud for base strategies.

### B7. Licensing/Data-Cloud tripwire
Predictive + base generative (Summaries, Service Replies) **don't need Data Cloud**; **RAG grounding, Enterprise Knowledge (Data 360), Service Intelligence DO.** Web-to-Case data isn't surfaced in Service Intelligence.

## PART C — Service AI Grounding & Prompt Templates
- **Two grounding paths** (often combined): **structured CRM** (records/fields/related-lists/DMOs via merge fields) and **unstructured RAG** (a retriever over a Data Cloud search index, surfaced as `EinsteinSearch:<retriever>.results`). Every prompt/response transits the **Einstein Trust Layer** (secure retrieval, dynamic grounding, **data masking** — can blank the very fields you want in a summary, review the policy — prompt defense, toxicity scoring, zero retention, audit/feedback in Data Cloud).
- **`GenAiPromptTemplate`** (v60+) + **`GenAiPromptTemplateActv`** move together (`genAiPromptTemplates/<Name>.genAiPromptTemplate-meta.xml`). `templateType`: `einstein_gpt__salesEmail`, `einstein_gpt__fieldCompletion`, `einstein_gpt__recordSummary`, `einstein_gpt__flex` (agent actions). 5 grounding mechanisms: record merge fields, related-list (JSON), **Flow** (Template-Triggered Prompt Flow), **Apex** (`@InvocableMethod` with `CapabilityType = PromptTemplateType://einstein_gpt__<type>` or `FlexTemplate://<API>`, returns a `prompt` var), **Retriever/RAG**.
  - **Gotcha:** bound Flow/Apex/custom fields/retriever **must pre-exist or co-deploy** (#1 deploy failure); a Flow referencing a template can throw "can't find an action…" (deploy together); scratch-org template deploys can error (use a sandbox with Einstein on).
- **Data Library / retrievers:** creating an ADL auto-provisions the Data Cloud stack (stream, DLO/DMO, vector store, **search index**, **retriever**, prompt template, action). Retriever metadata = **`AiRetriever`** (linked to a search index; auto-named `KA_*`/`File_*`); custom retrievers map `Chunk__c` (text the LLM reads) + `SourceRecordId__c` (drives citations). Search index: **Vector** vs **Hybrid** (recommended for service Knowledge). **The prompt template + `GenAiPlugin`/`GenAiPlannerBundle` deploy cleanly; full ADL provisioning (stream + vector store + index) is UI-reliable / DX-unreliable and must be recreated per org.** Data Cloud + default data space mandatory; index must reach "Ready" before answers return.
- **⚠️ `sf agent adl` CLI is dev-preview and BROKEN for Knowledge libraries (hard-won).** `sf agent adl create --source-type knowledge --primary-index-field1 Title --primary-index-field2 Summary` fails with **`INVALID_REQUEST_STATE: File operations are not applicable for KNOWLEDGE libraries`** and leaves a half-created **`SFDRIVE`** library behind (`sf agent adl list` to spot it; `sf agent adl delete -i <1JD…>` to clean up). `adl list/get/delete/status` work fine; only `create` for Knowledge is broken.
- **The Knowledge ADL via the Setup UI wizard (verified working path):** Setup → Quick Find **"Data Library"** → **Agentforce Data Library** → **New Library** (Name + API Name + Description) → on the library page pick **Data Type = Knowledge** (+ Data Space = default; the data type is immutable after save) → **Fields Settings**: choose **two Identifying Fields** (e.g. **Title** + **Summary** — these are the search/index fields) and optional **Content Fields** (the body) → **Save**. Confirm with `sf agent adl list` (Source Type shows **KNOWLEDGE**); the index builds async (status `UNKNOWN`→ready over minutes — poll `sf agent adl status -i <1JD…>`). The Beta Connect API is the other headless route.
- **Then it still has to be wired into the agent** (separate, versioned change): add the **"Answer Questions with Knowledge"** action under the agent's General FAQ topic → republish + `sf agent activate`. Building the library alone grounds nothing until the action is wired — and it's pointless until the KB has real content (an org with 1 article gains nothing).
- **Wiring grounding into a LIVE agent is a versioned change, not just a data step.** Once the ADL/retriever are Ready, add the **"Answer Questions with Knowledge"** action under the agent's **General FAQ** topic, then **republish + `sf agent activate`** (publish ≠ activate) and re-run evals. An action-centric production agent whose instructions say "never answer from memory / always call a service action" will NOT surface Knowledge until this action is explicitly wired — and bolting it on can regress behavior, so treat it as a deliberate agent version and don't bother until the KB has real content (grounding on 1 article is pointless).

## PART D — Einstein Bots vs Agentforce
- **Einstein Bots** = deterministic NLP-intent + author-defined dialog tree. Metadata (fully deployable): `Bot`, `BotVersion` (`botDialogs`, `mlIntent`), `MlDomain`, `BotTemplate`, `BotSettings`. **Enhanced Bots** required for modern Messaging + Agentforce handoff. Licensing = seat-based session allowance (~25 conversations/license/mo) — **cost bounded by seats, not per-conversation metered**. No announced EOL but frozen/legacy.
- **Agentforce** = `Bot`+`BotVersion`+`GenAiPlannerBundle` (Atlas planner over topics/actions). **Shares container objects with Einstein Bots but ZERO authoring objects** → no lossless converter; migration = rebuild (Beta tool gives a structural starting point only).
- **Hybrid (recommended):** an Enhanced Bot as the deterministic, low-latency, cost-bounded front door that **hands off to an Agentforce agent** for open-ended reasoning — caps Flex Credit spend. Bot captures category → writes a MessagingSession field → outbound Omni flow routes to the right agent.
- **When each:** Bots for strictly deterministic/compliance/low-latency transactional flows; Agentforce for open-ended NL Q&A and multi-step cross-system reasoning. Pin the model in Agent Script for predictability.

## PART E — Enablement / licensing
- **Settings toggles ARE deployable** (not UI-only): `EinsteinGptSettings` (`enableEinsteinGptPlatform`), `AgentPlatformSettings` (`enableAgentPlatform`), `BotSettings`, `EinsteinAgentSettings` (Classification + Wrap-Up), `OmniChannelSettings`, `ConversationalIntelligenceSettings`, `AIReplyRecommendationsSettings`. Scratch features: `Einstein1AIPlatform`. **UI/provisioning-only:** Data Cloud tenant provisioning, Trust Layer policy, MIAW deployment + snippet, edition/add-on entitlement, the `EinsteinServiceAgent` Agent-User picker.
- **Permission sets:** Agentforce Service Agent User + Permissions (on `EinsteinServiceAgent`); **a custom agent-user permission set with the object/field CRUD the agent needs — #1 silent-failure gotcha ("tests green, prod broke": the agent reasons fine but FLS/CRUD blocks the record write)**; Prompt Template Manager/User; Einstein for Service PSL; Data Cloud PSLs when grounding.
- **2026 consumption (pick one):** **Flex Credits** (per-action: $0.005/credit, standard action 20 credits=$0.10, voice 30=$0.15) — recommended for most; vs **Conversation-based** ($2.00/completed conversation, break-even ≈ 20 actions/conversation). Can't combine. Data 360 credits are a separate pool; Agentforce 1 Edition bundles both.
- **Canonical order:** entitlement → provision Data 360 (Trust Layer prereq) → turn on Einstein (`EinsteinGptSettings`) → Trust Layer policy → turn on Agentforce (`AgentPlatformSettings`+`BotSettings`) → Prompt Builder + perms → channels (MIAW + Omni flow + Route Work) → build/assign/**activate** agent (publish ≠ activate) → connect to channel → live E2E test.

## Top takeaways
1. Runtime = `Bot`+`BotVersion`+`GenAiPlannerBundle` (v64+); `AiAuthoringBundle` (`.agent`) is the DX source of truth.
2. Channel attach is **indirect** (Messaging → Omni flow → Route Work=Bot); **email is a separate path** (E2C + assignment to `EinsteinServiceAgent`).
3. **`publish ≠ activate`**; the agent user needs an explicit **CRUD/FLS permission set** or record creation silently fails.
4. Always include the **Escalation topic + availability-aware Omni flow**.
5. Anti-hallucination = gate confirmation on explicit action output + multi-turn evals.
6. Data Cloud tripwire: predictive + base generative don't need it; **RAG grounding, Enterprise Knowledge, Service Intelligence do.**

## Key doc URLs
[Get Started with Agents](https://developer.salesforce.com/docs/einstein/genai/guide/get-started-agents.html) · [Agent DX Metadata](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-dx-metadata.html) · [GenAiPromptTemplate](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_genaiprompttemplate.htm) · [AiRetriever](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_airetriever.htm) · [Recommendation](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_recommendation.htm) · [Trust Layer](https://developer.salesforce.com/docs/ai/agentforce/guide/trust.html) · [Org Setup](https://developer.salesforce.com/docs/ai/agentforce/guide/org-setup.html)
