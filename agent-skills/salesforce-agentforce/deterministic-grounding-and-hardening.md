# Deterministic grounding & agent hardening (anti-hallucination, runtime gotchas, guest cart, testing)

Hard-won patterns for making an Agentforce agent behave **deterministically** — say only true things, return real data, route correctly, and not break at runtime. Distilled from the Kwitko/Bean&Brew multi-brand commerce Concierge build. The throughline: **an LLM agent only stops hallucinating when the truth is in front of it as data — bound the words with a variable, bound the picks with a brand-scoped engine, and put guards in the subagent that actually runs the action.**

---

## 1. The grounding ladder (apply ALL layers, not just prose)

Telling the agent "don't invent products/specs/prices" in prose is **necessary but never sufficient** — the planner overrides prose under pressure. Ground deterministically at every layer:

| Layer | Mechanism | What it bounds |
|---|---|---|
| **Catalog variable** | a `linked string` agent var sourced from a stamped field; "CATALOG IS THE LAW" | what the agent may *mention/offer/recommend* |
| **Reco engine** | brand-scoped Apex (`Brand__c = :scope` on EVERY query) + `brand` an `@InvocableVariable(required=true)` | which products it *picks* |
| **Cart** | resolve the chosen item server-side by **exact Name** (brand-scoped), not by a reused Id | the cart never contains a *different* item than named |
| **Specs** | the spec text lives **inside the catalog variable** (in-context) AND on the picks (`primarySpecs`) AND a backup lookup action | the *details* it states |

**Rule:** the catalog variable bounds what it SAYS, but the engine + cart + specs must ALSO be deterministic data the platform returns — prose alone loses to the planner.

### 1a. Bake reference data INTO a linked variable (the single most robust anti-hallucination move)
Stamp the store's full catalog **with each product's real specs** onto a `MessagingSession` LongTextArea field at session start (before-insert trigger), and expose it as a `linked string` agent variable.

- Format each line `Name — specs` (abbreviate ~220 chars/product). Fits 32768 for ~100 products.
- Linked vars resolve at **session START**, are **FREE** (no action, no Flex credit), and are **immune to runtime/storage failures** (no action call needed to answer "tell me about X").
- This is strictly better than a runtime spec-lookup action for *listed* products: the agent already has the specs in context. Keep a lookup action only as a backup for arbitrary/unlisted items.
- Instruction: *"the catalog variable ALREADY contains every product's specs (each line is 'Name — specs') — answer details DIRECTLY from it; you already have them, so NEVER say you lack details for a listed product."*

### 1b. Make the deciding input REQUIRED
Make the scoping input (e.g. `brand`) `@InvocableVariable(required=true)` so the LLM **cannot** call the engine without it. Optional+blank = the engine silently defaults and cross-contaminates brands.

---

## 2. The two runtime gaps that make a NEW agent action silently return nothing
**Symptom:** the action works perfectly in admin anonymous Apex, but the *live agent* gets empty results and says "I don't have that information." Non-deterministic-looking (your tests pass, user sessions fail). Both are invisible unless you test as the agent's runtime user (a live MIAW session, not `sf apex run`):

1. **`with sharing`** → the guest/MIAW running user can't see the records → 0 rows. **Every agent-invoked data action must be `without sharing`** (the agent runs as a low-privilege messaging/guest user). Match the existing working actions.
2. **No Apex class access** → the new class isn't in the agent's **runtime permission set** `<classAccesses>` → the action can't execute → returns nothing. **Add every new action class to the runtime permset** (the one that grants the existing actions).

> **CHECKLIST for any new agent action class:** `without sharing` ✓ + `<classAccesses>` grant in the runtime permset ✓ + FLS on any new field it reads/writes ✓. Miss any one → silent no-op live.

---

## 3. Put guards in the subagent that RUNS the action, not just where it "should" live
The Atlas planner routes a message to whichever subagent it judges best — and **instructions in subagent A do not apply once it routes to subagent B**.

- Real case: a shopper said "i want to **buy**" then "first one." The planner routed "first one" to `cart_builder` (because of the earlier buy intent), so the "show details first" rule in the `shopping` subagent never fired → it hit the add-to-cart path and dead-ended on a registration gate.
- **Fix:** the guard had to live at the TOP of `cart_builder` itself: *"if the CURRENT message is only a positional/name reference with no explicit add/buy/checkout verb → this is a DETAILS request, show specs, do NOT add to cart."*
- **Lesson:** for any cross-cutting rule (bare selection, identity gate, brand scope), replicate it in **every subagent that can receive that intent**, especially the one holding the side-effectful action.

---

## 4. Positional references to a list ("first one", "the last one", "top/bottom/middle")
The agent must map a bare position to the item it just listed. Add an explicit rule:
> *"When you have just shown a list and the shopper replies with a POSITION — first/second/third/last/bottom/top/middle one, an ordinal, 'that one' — they mean the item at that position IN THE LIST AND ORDER YOU JUST SHOWED (top = first, bottom = last). Resolve by counting position; never ask them to re-name it. A bare positional ref defaults to 'tell me about that one' (details), NOT 'add to cart'."*

Pair it with the §3 guard so the details-vs-cart routing is correct.

---

## 5. RAG for product specs / knowledge — reuse the existing retriever
In a DE/most orgs there is **no `AiRetriever` / data-library metadata type and no Connect data-library API** — the vector index + retriever are Setup-UI artifacts. But the standard **`AnswerQuestionsWithKnowledge`** action (`target: standardInvocableAction://streamKnowledgeSearch`, carrying a real `ragFeatureConfigId`) **grounds directly on published Salesforce Knowledge**. So:
- "Reuse what we have" = **load the corpus as published Knowledge articles**; the existing action retrieves them. No new infra.
- These Lightning-Knowledge articles store their body in the **`Summary`** field (Text Area 1000) when there's no rich-text field — fine for compact spec sheets.
- **Pack** articles (one per brand+family, body = "Name: spec | Name: spec…") to fit storage; `Product_Specs__c` is a LongTextArea so it **can't be filtered in SOQL `WHERE`** (filter in Apex).
- Publish via `KbManagement.PublishingService.publishArticle(knowledgeArticleId, true)`.
- ⚠️ The vector index is **async** — SOSL finds new articles within minutes but `streamKnowledgeSearch` grounding lags (hours). Keep a deterministic fallback (the in-variable catalog / a lookup action) for immediacy.

---

## 6. Guest cart vs gating — gate ACCOUNT actions, never cart
- **Guest add-to-cart should work on every storefront.** Don't gate the cart on sign-in/registration. Registration/verification is only for **protected account actions** (order status, returns, refunds, cancellations, address/payment).
- Watch for an asymmetry: a WooCommerce store gives a one-click `?add-to-cart=<id>` link (guest-OK), while a Salesforce **D2C/LWR** store may have a `WebStoreBuyerGroup` "registered buyer" gate baked into your CartLinkService — remove it so D2C guests get the **product-page link** to click "Add to Cart" (D2C has no one-click-add URL).
- Remove the gate in **both** places: the Apex (return the link, set `isRegisteredBuyer=true`) AND the cart subagent instruction (delete the "not a registered buyer → refuse" rule).

---

## 7. Storage on Developer Edition is a hard wall — and it breaks more than Analytics
DE caps **Data Storage at 5 MB**. Two platform-generated record types fill it and are **un-deletable by any means available to an admin**:

| Consumer | Created by | Deletable? |
|---|---|---|
| **AI Evaluation results** (`AiEvaluation`, `AiEvalTestCaseResult`, `AiEvalTestCaseCritRslt`, `AiEvalCopilotTestCaseRslt`) | every `sf agent test` / eval run | ❌ SOQL/DML/Tooling/Bulk all "not supported"; no Lightning list view; Test Suites UI is empty (CLI runs don't appear); deleting the `AiEvaluationDefinition` does NOT cascade results |
| **Agent-publish CMS artifacts** (`ManagedContent`: `agent_graph__agentAssets` + `next_gen_agent_authoring__resource`) | every `sf agent publish` (~2 records/version × all agents) | ❌ Apex "Delete not allowed"; Bulk "No delete access"; Connect CMS API no-op; CMS workspace UI "you do not have the level of access" |
| MessagingEndUser (orphaned test users) | chat sessions | ⚠️ blocked if any session has an open Conversation; Conversation delete itself "not allowed" |
| AsyncApexJob | batch/scheduled runs | ❌ "No delete access" (and usually not a storage consumer anyway) |

**Consequences of being over 100%:**
- The async **Sessions & Intents** processing can't persist → **Intent tag + Custom Scorer columns go null** for all new sessions (this is the "why did it go null today" answer — eval runs you did *today* tipped it over).
- Action invocations can **intermittently fail** (their logging writes hit the cap) → an action returns empty non-deterministically. **Mitigation: §1a — put the data in a linked variable so the answer needs no runtime action.**

**There is NO programmatic purge.** Options: Salesforce **Support** purge, a **fresh/bigger org**, or **stop generating** it (don't over-run evals; minimize republishes — each adds CMS artifacts). To verify the breakdown, screenshot **Setup → Storage Usage** (it renders in a cross-origin iframe — read it via a browser *screenshot*, not DOM/API).

---

## 8. Scorers reality (DE)
- The live **Scorers** grid (`?c__nav=customEvals`) shows only **auto-provisioned Standard scorers** (Abandonment, Deflection, …). **Live custom-scorer creation is a DE dead-end** (no New button; `AiAgentScorerDefinition` won't deploy).
- What you "create via API" is an **offline `AiEvaluationDefinition`** — it scores **eval test cases**, not live sessions, so it **never populates the live "Custom Scorers" column**. That column stays null on DE regardless.
- Sampling can silently reset to 100% across republishes — fine (more coverage), but it's not why a column is null (null = storage/over-cap or no live scorer).

---

## 9. Live MIAW test harness (real runtime, no eval-record bloat)
The honest end-to-end test = a real headless SCRT/MIAW conversation (does NOT grow the AI-eval hog; it writes a small MessagingSession). Reusable recipe:
1. `POST /iamessage/v1/authorization/unauthenticated/accessToken` `{orgId, developerName:<channel>, capabilitiesVersion:"260"}`.
2. Open SSE `GET /eventrouter/v1/sse` — **`X-Org-Id` MUST be the 15-char org id** (not 18); keep the thread alive (precondition for conversation create).
3. `POST /iamessage/v1/conversation` `{conversationId, routingAttributes:{Brand__c:"…"}}`.
4. `POST …/conversation/<id>/message` per turn; read agent replies from `CONVERSATION_MESSAGE` SSE events (`conversationEntry.entryPayload…staticContent.text`).
- ⚠️ **Brand is stamped from the CHANNEL devname**, not the routing attribute — use the *right channel* to test a brand (e.g. `Kwitko_Web_Chat_V2` → Kwitko, `Bean_Brew_Web_Chat` → Bean & Brew). Wrong channel → wrong store.
- Test the actual failing utterances verbatim (e.g. "i want to buy" → "first one" → "yes"); LLM routing is non-deterministic, so re-run a few times.

---

## 10. Publish/activate discipline
- `sf agent publish authoring-bundle --api-name <X>` then **`sf agent activate --api-name <X> --version <highest>`** — publish does NOT activate; always activate the highest version and verify the Active version before testing.
- Agent-level variable **descriptions max 255 chars** (publish fails otherwise).
- Data-only changes (catalog field content, `Brand__c` re-tag, FLS) need **no republish** — the catalog variable rebuilds per session.
