# Agent Discovery & Intake — ask, research, confirm, THEN design

**Run this BEFORE `solution-design-process-outcomes.md`.** You cannot design an agent for a business
you haven't interviewed. Building from assumptions is the second root cause of bad agents (the first
is no process/outcome map). This file is the structured intake: what to ask the user, what to research
yourself, and what concrete inputs to pin down so the design is right the first time.

> Operating principle: **Gather → Research → Propose → Confirm → only then build.** Never invent the
> business process, the data model, or where data lives. Ask. For anything the user can't answer off
> the top of their head, you ask for the *concrete artifact* (object/field API name, endpoint URL, a
> screenshot of the setting/UI, a sample record). You are allowed — encouraged — to bring expertise:
> research the industry's standard process online and from your own knowledge, propose the best-practice
> flow, then have the user confirm/correct it. But the FACTS about their org and systems come from them.

## The discovery loop (how you run it)
1. **Frame** — tell the user you'll run a short discovery before building, and that you'll ask for
   specific inputs (API names, URLs, screenshots) as you go.
2. **Interview** — work through the question bank below, ONE topic at a time. Don't dump 40 questions
   at once; ask a topic, react to the answer, drill in.
3. **Research in parallel** — for the industry + process, research best practice (web + your own
   knowledge + `context7` for any tool/API). Bring a proposed standard flow to the user instead of a
   blank "tell me your process."
4. **Propose** — restate the process you heard as a draft flow + the data/systems it needs. Show it
   back. Let them correct it. This catches wrong assumptions before code.
5. **Confirm the hard, expensive decisions** (the "get it right the first time" list) explicitly.
6. **Produce the discovery output** (artifacts below) → hand off to `solution-design-process-outcomes.md`.

## Question bank — ask these, grouped by topic

### A. Business & industry context
- What industry / what does the business do? Who are the end users of this agent (customers? staff?)
- What is the ONE job this agent must do well? (Scope it; resist "do everything.")
- What does success look like — what outcome / metric proves it works?
- What must it NEVER do (brand, legal, compliance red lines)?
- *(You research:)* the standard process for this job in this industry, common edge cases, and
  regulatory constraints (refunds, PII, healthcare, finance, etc.). Bring this to the table.

### B. The process(es) to automate — one at a time
For EACH process the agent should handle, get:
- **Start point / trigger** — how does it begin? (user message in web chat? an inbound email? a
  record created? a scheduled time?) "Where is the starting point?" is a required answer.
- **Happy-path steps** — the ideal sequence end to end.
- **Decision points** — every branch ("if delivered → … / if not → …").
- **Terminal outcomes** — every way it can END (success + each failure/refusal). These become the
  process/outcome matrix.
- **Who/what is authoritative** for each fact (which system is the source of truth).
- **Confirmation / approval points** — anything money-moving, destructive, or compliance-sensitive.

### C. Systems & data — "what is the data, from where, and how"
> STANDARD-FIRST: for each data need, first identify the **standard object** that models it (research the
> Object Reference + inspect the org with `sf sobject describe`) before proposing any custom object/field.
> See `standard-objects-and-declarative-first.md`. Prefer **Flows** over Apex for the automation behind it.
- For each piece of data the process needs: **which system holds it?** (Salesforce object? an external system? an
  external API? Data Cloud DMO?) **What's the source of truth** if more than one holds it?
- **Concrete identifiers** — object + field **API names** (e.g. `Order.Fulfillment_Status__c`),
  record types, picklist values. Ask for these explicitly; don't guess `__c` names.
- **How do we read/write it?** — sf CLI/metadata, Connect/REST API, an Apex service, an external
  callout (Named Credential?), Data Cloud query. Prefer DX/CLI/API (see SKILL.md rule #1).
- **Auth** — how is the external system authenticated? Who is the running user / what's its access?
- **Data quality** — is the key field actually populated? (See the empty-identity-key gotcha in
  `data-cloud.md` — a real, silent killer.)
- Ask for a **sample record** or a screenshot of the data in its UI to verify field names/shape.

### D. Channel, UX & identity — where it runs and who's talking
- **Where does the agent live?** MIAW web chat, Slack, Experience Cloud, headless/API, internal?
  (This sets employee vs Service Agent — IMMUTABLE after first publish.)
- **Where in the UI is the entry point?** (the page, the button, the embed.) Ask for the URL /
  screenshot of where users start.
- **Identity** — are users authenticated? How do we KNOW who they are (verified token, pre-chat
  field mapped to a Messaging Session field, SSO)? Identity must be a GATE on a verified value, never
  a user's claim. Confirm exactly how the verified identity reaches the agent. (See `messaging-web.md`.)
- **Tone / persona / language(s).**

### E. Actions, integrations & outputs — what you must build
- For each process step that DOES something: what's the **action** (Apex invocable / Flow / standard)?
  What are its **inputs**, and what **outcome flag + message** does it return? (Every action needs a
  machine-checkable success/created/found flag — that's the anti-hallucination contract.)
- What **integrations** are required (commerce/ERP, payment, shipping/tracking, email/ESP, external API)?
  Credentials? Rate limits? Sandbox vs prod endpoints?
- What gets **created/updated** as proof (a Case, a refund, a record, an email)? Ask the user to
  confirm what artifact each outcome should produce.
- **Outputs YOU need from the user** (collect these as you go — this is the "I'll give it to you"
  list): object/field API names, record type names, picklist values, the deployment/site name, the
  org id, endpoint URLs + secrets (via a safe channel), screenshots of the relevant Setup pages and
  the live UI entry point, sample records, and confirmation of the source of truth per fact.

### F. Not-covered / fallback — kill hallucination at the edges
- What's explicitly **out of scope**? Where should the agent hand off (a queue, a human, a callback,
  an escalation case)?
- What does the agent say when it CAN'T do something? (It must decline honestly + escalate — never BS.)
- Who owns the escalation path (queue, team, SLA)?

### G. Guardrails & compliance
- PII rules (what may it read back, to whom, only after verification).
- Consent (marketing/contact) — stored where, gate on it.
- Money-moving / destructive actions — confirm-before-execute, caps (e.g. goodwill credit ≤ $X).
- Audit/traceability — what must be logged (who/when/why) for each action.

## Get-it-right-the-first-time checklist (pin these BEFORE first publish)
These are expensive or immutable to change later — confirm explicitly with the user:
- [ ] **Agent type**: employee vs Service Agent (IMMUTABLE after first publish — `agentforce-agents.md`).
- [ ] **Channel + deployment**: MIAW/Slack/headless; deployment & site naming.
- [ ] **Identity mechanism**: exactly how verified identity reaches the agent (and tested it does).
- [ ] **Data model**: every object/field API name, record types, who's source of truth (confirmed populated).
- [ ] **Action inventory**: one action per capability, each with an outcome flag (no capability without an action).
- [ ] **Process/outcome coverage**: every process has all outcomes enumerated incl. failure + not-covered.
- [ ] **Naming conventions**: agent dev_name, action labels, fields — consistent, namespaced.
- [ ] **Environments**: sandbox vs prod, storage headroom (MIAW 412 = storage full — `troubleshooting.md`).

## Discovery output (what you produce, then feed to solution-design)
A short discovery brief in the repo (e.g. `docs/agents/<Agent>-discovery.md`) containing:
1. Business/industry summary + the agent's one job + success metric + red lines.
2. Per-process: start point, steps, decision points, terminal outcomes, source of truth.
3. Data inventory: each datum → system → API name → read/write method → auth → populated? (yes/no).
4. Channel + identity mechanism (confirmed).
5. Action/integration inventory: action → inputs → outcome flag → artifact produced.
6. Out-of-scope list + escalation path.
7. The get-it-right checklist, all boxes confirmed.

→ Hand this to `solution-design-process-outcomes.md` to build the capability map, process/outcome
matrix, and decision trees. Discovery answers "what & where"; solution-design answers "how the agent
decides & never fakes it."

## Anti-patterns (don't do these)
- Building from your assumption of the process instead of asking. (You may PROPOSE from research —
  then confirm.)
- Guessing `__c` field/object API names. Ask, or retrieve from the org.
- Designing actions before knowing where the data lives and whether the key field is populated.
- Skipping the identity question — "they said they're logged in" is not identity.
- Asking the user one giant wall of questions. Go topic by topic; bring research, not a blank form.
