# Solution Design → Process/Outcome Map → Agent Decision Tree

**Read this BEFORE writing a single line of agent instructions.** Skipping it is why an agent
"trusts that the user is logged in," promises a refund, claims a case was opened — and none of it
happened. An LLM with a vague prompt and loosely-wired actions will **fill every gap by inventing a
plausible outcome.** The cure is not more prose in the prompt; it is a complete, explicit map of
every process, every outcome, and the action that produces each one — with a defined branch for
"can't" so there is no gap left to hallucinate into.

> Hard principle: **An agent may only ASSERT an outcome that an action RETURNED in this turn. Every
> conversational branch must terminate in either (a) a real action result, or (b) an honest "I can't
> do X" + a real escalation. There is no third option. "BS a friendly success" is a design defect,
> not a model quirk.**

---

## The 4 design artifacts (build them in this order, before the .agent file)

### 1. Capability map — what is this agent ALLOWED to do?
List every business capability and bind each to ONE action. **Prefer a Flow action or a thin
`@InvocableMethod` Apex over a STANDARD object** (Order/Case/ReturnOrder/Shipment/CreditMemo…) — research
standard objects + declarative options first (`standard-objects-and-declarative-first.md`); justify any
custom object or pure-Apex action. If a capability has no action, the agent CANNOT do it — say so explicitly
in the prompt and route it to escalation. A capability with no backing action is the #1 hallucination source.

| Capability | Action (apex://) | Money/data-moving? | Precondition |
|---|---|---|---|
| Order status / tracking | OrderStatusService | read-only | verified identity |
| Return + refund | ReturnService | YES (refund) | verified + DELIVERED + explicit confirm |
| Free replacement | ReshipService | YES (goods) | verified + confirm |
| Exchange | ExchangeService | YES | verified + DELIVERED + confirm |
| Cancel | CancellationService | YES (refund) | verified + NOT shipped + confirm |
| Open / escalate case | CaseService | logs | verified (or guest for generic) |
| Store credit (goodwill) | (apply_store_credit) | YES (≤$50) | verified + confirm |

### 2. Process–Outcome matrix — every intent × every TERMINAL outcome
For each process, enumerate **all** outcomes, not just the happy path. Each row is a leaf the agent
must handle with a specific, truthful response. The failure modes are the whole point.

Example — **Return**:

| # | Outcome | Trigger | Agent must say/do | Source of truth |
|---|---|---|---|---|
| R1 | Success | action returned `created=true` | state return #, refund amount, return tracking IN CHAT | `@outputs.returnOrderNumber/refundAmount` |
| R2 | Not eligible — not delivered | `canReturn=false` (Shipped/Processing) | quote real status, offer tracking or case — DO NOT start | `@outputs.fulfillmentStatus` |
| R3 | Not verified | action returned sign-in message | present `sign_in_link`; reveal NOTHING | `IdentityService.isVerified=false` |
| R4 | No order found | `found=false` | say no order found for that email; offer to recheck | action result |
| R5 | Item not matched | `process_return` couldn't match `itemsToReturn` | show real items, re-ask which | action message |
| R6 | Window expired / non-returnable | action refuses | relay the real reason; offer goodwill/case | action message |
| R7 | Action errored / unavailable | exception / no success flag | apologize, OPEN A CASE — never claim it worked | (no success flag) |

If a cell has no defined response, the agent will invent one. **Fill every cell.**

### 3. Decision / solution tree — per process, gates → action → outcome branches
Each process is a tree. **Nodes are gates or action calls; leaves are the matrix outcomes.** Every
path from root to leaf ends in a real result or an honest decline. Example — **Return**:

```
RETURN request
 ├─ GATE identity verified?  (loggedInEmail non-empty AND IdentityService.isVerified)
 │     └─ NO → R3: sign_in_link, reveal nothing. STOP.
 ├─ ACTION get_order_status (this turn, no "one moment")
 │     ├─ found=false → R4
 │     └─ found=true → SHOW order# + items + status
 ├─ GATE canReturn?
 │     └─ false → R2: quote status, offer tracking/case. STOP (no return).
 ├─ ASK which items + refund-vs-replacement-vs-exchange
 ├─ CONFIRM "Return <items> from <order>, refund <amount>?"  (money-moving → mandatory)
 └─ ACTION process_return(confirmed=true)
       ├─ created=true  → R1: state return#, refund, tracking IN CHAT
       ├─ item unmatched → R5: re-ask
       └─ error/no flag → R7: open case, DO NOT claim success
```

Author one tree per capability (status, cancel, exchange, address change, failed payment, etc.).
The tree IS the spec for the subagent's `reasoning.instructions` and `actions:` wiring.

### 4. Coverage / uncovered-intent rule
Anything not in the capability map is **out of scope**. The agent must NOT improvise. Define one
explicit branch: *"If the request isn't a capability you have an action for, say you can't do that
directly and open an escalation case (`open_case` escalate=true) or hand off."* No silent gaps.

---

## Identity is a GATE, not a claim
The agent must treat verification as a precondition derived from a **verified variable**, never from
the shopper saying "I'm signed in." A user asserting they're logged in proves nothing. The gate is:
`loggedInEmail` (from `$Context`/MessagingSession) is non-empty AND every gated action is passed
`verifiedEmail=loggedInEmail` AND the Apex `IdentityService.isVerified()` returns true. If that
variable is empty, the shopper is effectively a guest no matter what they type — present the sign-in
link; reveal/act on nothing. (A real service rep confirms identity before touching an account; the
agent must too.) **If the verified email never arrives, the whole tree collapses to R3 and the agent
will look like it's "trusting blindly" — fix the identity plumbing first, see `messaging-web.md`.)

---

## Anti-hallucination is enforced in TWO layers (defense in depth)
1. **Action layer (hard truth):** every action returns a machine-checkable outcome flag —
   `created` / `success` / `found` / `canReturn` / `eligible` + a human `message` and a `reason` on
   refusal. The action — not the model — decides what happened. Gate money/data moves in Apex too
   (`without sharing`, identity + eligibility) so a prompt slip can't cause a bad write.
2. **Reasoning layer (contract):** the prompt states, per action: *"You have NOT <done X> unless
   `@actions.X` returned `<flag>=true` in THIS turn. Never say it happened, is 'being processed', or
   that an email 'will arrive' otherwise."* Relay `@outputs.message`/IDs verbatim as the in-chat
   source of truth; the emailed copy is secondary, never the only confirmation.

If an action wasn't called, the thing did not happen — full stop. "It will arrive shortly" for an
action you didn't invoke is a hallucination.

---

## Verification matrix — every leaf gets a test
A process isn't "done" until **every outcome leaf** is proven, not just the happy path. For each
matrix row: an `sf agent test` case (assert `expectedActions` + verifiable side effect) AND/OR an
Apex test of the action's flag, AND a live chat smoke for the headline paths. Specifically prove the
**negative** leaves: not-verified reveals nothing, not-eligible refuses, errored-action opens a case
instead of faking success. (Watch the storage/AI-Evaluation hog from `sf agent test` — see
`troubleshooting.md`.)

---

## Where this lives in the build
- Artifacts 1–4: keep as a markdown/board doc in the repo per agent (e.g. `docs/agents/<Agent>-design.md`) — the single source of truth the prompt is generated FROM.
- The trees become the subagent `reasoning.instructions` + `actions:` wiring in
  `aiAuthoringBundles/<Agent>/<Agent>.agent` (see `agentforce-agents.md` for syntax).
- The outcome flags live in each Apex action's `Result` class.
- Context/identity variables are declared on the `Bot` (`contextVariables` ← MessagingSession fields)
  and referenced in the prompt; the gate is enforced in `IdentityService`.

## Failure post-mortem this file exists to prevent
Symptom: signed-in shopper asks to return; agent says "you're signed in, I'll start your return…
I'll open a case… I'll process your refund" — **no order was ever fetched, no case/refund created.**
Root causes, each a missing artifact above: (1) identity treated as a user claim, not a verified gate
(no Artifact-3 gate enforced) → loggedInEmail was empty and nothing caught it; (2) outcomes R3/R4/R7
not forced, so the model invented R1; (3) actions narrated, not called, because the prompt didn't bind
"assert only on returned flag." Build the four artifacts and every one of these is structurally
impossible.
