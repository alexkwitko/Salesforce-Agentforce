# Designing Agentforce for fewer Flex Credits

Agentforce production usage is metered in **Flex Credits**, and the meter is driven by **exposed Agentforce actions**, not by conversation or routing. Design every agent so the LLM *converses and explains* while **Apex/Flow executes the business logic in as few exposed actions as possible**. Always **validate the actual per-action metering in Digital Wallet** — treat the rates and "what counts" below as guidance to confirm, not gospel.

## The pricing reality (confirm in Digital Wallet)
- **Standard / custom Agentforce action ≈ 20 Flex Credits**; **voice action ≈ 30**. (~20 credits ≈ $0.10; 100k credits ≈ $500.)
- An **action** = an exposed step the agent executes: run Apex, run a Flow, answer with Knowledge/retrieval, update a record, summarize, run a prompt template, call a tool/API.
- **Topic / subagent selection inside ONE agent is generally NOT metered as an action** by itself (it's planner reasoning) — but confirm in Digital Wallet, which reports usage by agent/action/use-case.
- **Agent-to-agent (A2A / connected-subagent) handoffs**: the routing itself may be free, but **each connected specialist runs its own billable actions** — validate in Digital Wallet before assuming a topology is "cheaper."

## The one rule
**The cost driver is exposed actions — not topics.** Do not let the LLM "think through" business logic step-by-step by firing action-after-action. Let Salesforce execute the chain inside **one** action.

> Bad: Agent → lookup action → segment action → engagement action → order action → case action → respond. (many billable actions)
> Good: Agent → **one** `getCustomerContext` action (Apex/Flow chains all of it internally) → respond. (one billable action)

## Design patterns that cut credits

1. **Consolidated action chains, never action-over-action.** Each use case = ONE exposed `@InvocableMethod`/Flow that internally does the whole chain (resolve → query CRM + Data Cloud → compute → write record → log → return one compact payload). Build per-use-case orchestrators: `getCustomerContext`, `getLeadContext`, `getCaseContext`, `getProductContext`, `getConsentContext`. A wrapper that internally calls other Apex methods is still **one** agent action.

2. **One unified context action, fetched ONCE per session, cached in a VARIABLE.** Call the shared context orchestrator once; `set` its result into a mutable session variable and reuse the variable in every subagent. Re-calling it per turn burns an action each turn for no new info. Guard it: `if contextLoaded is TRUE, reuse @variables.contextSummary; else call + set the flag and the variable.`
   - ⚠️ **Do NOT** "cache" by writing context to a custom object that each agent then **re-queries** — that read is itself a billable action every turn. Cache in a **session variable** (free within the session). Use a custom journey object only for **cross-session/cross-agent** memory, read **once** via the single context action.

3. **Data Cloud: prepare → package → explain.** Don't let the agent hit Data Cloud N times. **Data Cloud prepares** the intelligence (segments/scores/NBA) — ideally **pre-materialized onto a CRM record asynchronously** (e.g. a `DataCloudAugmentation` service that runs the DMO joins and writes Account fields). **Apex/Flow packages** it into the one context action (a cheap CRM read, not live DMO queries per turn). **Agentforce explains** the result. Note: Data Cloud DMOs queried from Apex run in system mode — enforce your own access/privacy gating.

4. **Return a small, gated payload — not raw records.** The context action returns a compact object (`customerFound`, `identityVerified`/`privacyMode`, `segments`, `recentOrders`, `openCases`, `nextBestAction`, `agentInstruction`), and clears private fields unless verified. Never return 50 raw rows the agent must reason over.

5. **ONE ACTION PER TURN.** Write it into every subagent's reasoning so the planner can't stack 3 actions in a single turn.

6. **Deterministic logic in Apex/Flow/CPQ, not the LLM.** The agent collects inputs and narrates; pricing, eligibility, validation, ranking, dedup, CPQ rules run in code. Fewer model round-trips and fewer actions.

7. **Knowledge/retrieval sparingly.** Use it only when needed; limit retrieval to the top 3–5 chunks.

8. **Topics over agent-to-agent unless there's real reuse.** A monolithic agent with many topics is usually cheaper than A2A orchestration because it avoids extra handoff/planning layers and duplicate context/action calls. Reserve A2A for specialists with genuine standalone reuse (invoked by Flows/other channels too) — and confirm the cost in Digital Wallet.

9. **Lower scorer/evaluation sampling.** Standard scorers (LLM-as-judge) run on a % of sessions and consume credits — sample at ~20%, not 100%, on dev/low-volume orgs.

10. **Keep prompts tight** and avoid redundant tool definitions.

## The layered architecture to aim for
- **Agentforce** = conversation layer (collect + explain)
- **Flow / Apex** = orchestration layer (one consolidated action per use case)
- **Data Cloud / CPQ / Pricing** = decision layer (prepare the intelligence, ideally pre-materialized)
- **Digital Wallet + Agent Analytics** = control layer (meter actual usage by agent/action/use-case; this is the source of truth for what is and isn't billed)

## Quick design checklist
- [ ] Does each use case call exactly ONE exposed action (chain inside Apex/Flow)?
- [ ] Is the shared context action called ONCE per session and cached in a **variable** (not re-queried, not via a re-read custom object)?
- [ ] Is Data Cloud intelligence pre-materialized so the per-turn read is a cheap CRM query?
- [ ] Is "ONE ACTION PER TURN" enforced in every subagent?
- [ ] Is deterministic logic in Apex/Flow, not the model?
- [ ] Are A2A handoffs justified by real reuse (vs. cheaper topics)?
- [ ] Have you validated the real per-action meter in **Digital Wallet** rather than assuming?

## Conversation abuse / loop protection (MANDATORY — every agent ships with it)

Agentforce/MIAW has **NO native repeat-detector, no max-turns cap, and no cooldown** — only a session inactivity timeout. A user (or bot) repeating a question forever keeps the agent answering, and if each repeat re-fires an action (~20 credits) it's runaway cost. You MUST build the protection; an agent without it is not production-ready.

**The metering nuance that drives the design:** Flex Credits meter executed ACTIONS, not turns. So repeats are *cheap* if answered from cache (no action) and *expensive* if each one re-fires an action. Protection = (a) never re-run an action to repeat an answer, (b) a behavioral exit, (c) an edge rate-limit.

**Layer 1 — always-on in-agent guard (mandatory, free).** An agent-level instruction, in scope for every topic:
> "NEVER call an action to re-answer a question already answered this conversation — answer from cache/variables/your prior answer. If the shopper sends essentially the SAME request 3+ times after you answered it, do NOT run any action: acknowledge once, ask if there's anything else, and if they keep repeating, offer a human (open_case escalate=true) or to end the chat, then stop re-engaging that loop."

This is free (no per-turn action), works **mid-session** (the planner judges repetition from the transcript), and directly kills repeat-action burn. **Do NOT implement the counter as a per-turn guard ACTION** — that itself costs ~20 credits/turn and defeats the purpose. Use the instruction + the model's transcript awareness. (Proven live: by the 3rd identical ask the agent stops re-running the action and redirects/offers exit.)

**Layer 2 — deterministic server-side hard stop: NOT viable on native MIAW (verified — do NOT promise an Apex trigger).** The building blocks aren't there: `ConversationEntry` (the per-message object) is **NOT Apex-triggerable** (`EntityDefinition.IsApexTriggerable = false`), and `MessagingSession` — which IS triggerable — only **finalizes `EndUserMessageCount` at session END** (it reads 0 on an Active session; the real count appears only once Ended), so it isn't updated per inbound message and an update-trigger can't catch a flood mid-conversation. There is no triggerable per-message hook to cap or end a flooded Enhanced-Messaging conversation from Apex (a flag set mid-session also can't be read back via a linked agent variable — those resolve at session START). So on native MIAW the deterministic mid-session stop relies on **Layer 1 (instruction guard) + Layer 3 (edge)**, not a trigger. A trigger-based message cap IS doable only on a **custom/owned channel** where you persist each inbound message to a triggerable object yourself.

**Layer 3 — edge controls.** ⚠️ For native MIAW the chat UI runs in a **Salesforce-hosted iframe** and the conversation goes to a **Salesforce-hosted SCRT endpoint**, so the parent page can't read keystrokes inside the iframe and you can't WAF Salesforce's domain — per-message client throttling is **limited** on MIAW. What DOES work on MIAW: **CAPTCHA / bot-check before the chat opens** (gates session creation), the **session inactivity timeout**, pre-chat friction, and **monitoring + Digital Wallet alerts**. Full per-message client-side rate-limiting/cooldown is only available on a **custom/owned chat front-end** (your own UI calling the SCRT API), where you control the send path. Salesforce will not cool down the user for you.

**Checklist additions:**
- [ ] Is the always-on loop/abuse guard in the agent's top-level instructions (no action re-run on repeats → acknowledge → escalate/end)?
- [ ] Is the repeat-guard implemented as INSTRUCTION (free), not a per-turn guard action (billable)?
- [ ] Is there an edge rate-limit / CAPTCHA so floods never reach the channel?
- [ ] Confirmed: no native cooldown exists — the exit criteria + cooldown are built, not assumed.
