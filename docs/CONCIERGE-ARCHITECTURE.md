# Kwitko Concierge Web — Architecture & Flex-Credit Optimization

Customer-facing Agentforce **Service Agent** (`Kwitko_Concierge_Web`, Agent Script authoring bundle)
serving two brands (Kwitko Coffee + Bean & Brew) in one chat: shopping/recommendations + order,
account, subscription, and equipment-maintenance self-service — never revealing protected data to an
unverified shopper.

Active version: **v102** (Atlas reasoning engine).

---

## 1. Agent structure (router + topics)

`start_agent agent_router` is the entry point (the `start_agent` keyword is what invokes it — nothing
in the system instructions). It runs first, routes the message to ONE topic, and hands off. After a
hand-off the chosen topic owns subsequent turns until *it* transitions; cross-topic moves are
point-to-point (e.g. `service ↔ identity_gate`, `shopping → cart_builder`) plus two router safety-net
actions.

Topics (subagents):

| Topic | Purpose |
|---|---|
| `agent_router` | Entry/dispatch + 2 deterministic safety-net actions (`sign_in_link`, `process_return`) |
| `shopping` | Browse + recommendations + lead capture (renamed from `concierge` for clarity) |
| `cart_builder` | Turn "buy this" into a real cart link |
| `service` | Orders, tracking, returns, refunds, cancel, cases, **equipment maintenance** |
| `subscriptions` | Coffee-club self-service (gated `Sub*Web` wrapper actions) |
| `identity_gate` | Verify a guest (OTP email code or sign-in link) before protected help |
| `GeneralFAQ` | Knowledge-grounded answers |
| `off_topic` | Politely decline out-of-scope requests |

The router safety-net actions exist because two fragile moments (post-OTP return follow-up; "I'll sign
in") get mis-routed if handed off — so the router acts in place for those.

---

## 2. Variables: free (linked) vs billable (action-fed)

The cost driver in Agentforce is **exposed actions** (~20 credits each), NOT topics/routing.
**Reading a variable is free.** How a variable is *populated* determines cost:

- **`linked` variable** → resolved once at session start from a record field. **No action, no Flex.**
  - `brand ← MessagingSession.Brand__c`
  - `loggedInEmail ← MessagingSession.Kwitko_Logged_In_Email__c`
  - `sessionContext ← MessagingSession.Customer_Brief__c`  *(see §4)*
- **mutable variable fed by an action's output** → costs the action.
  - `agentContextSummary ← get_agent_context` (~20 cr) — kept only as a fallback.

**Principle:** pre-stamp everything onto the record via triggers, read it via linked vars for free,
and reserve billable actions for things that must be computed live or that *act* (return/cancel/book).

---

## 3. Brand scoping (free, via trigger)

`brand` tells the agent which store the chat is on, scoping recommendations and maintenance to the
right catalog. It is populated with **zero Flex**:

```
MessagingChannel (Kwitko_Web_Chat / _V2 → "Kwitko Coffee", Bean_Brew_Web_Chat → "Bean & Brew")
   │  (before-insert Apex trigger)
MessagingSessionBrandStampTrigger → MessagingSessionBrandStamp.stamp()
   │  writes
MessagingSession.Brand__c
   │  (linked var, resolved at session start)
agent variable `brand`
```

**Null-brand handling:** the system block + `service` topic require `brand`; if empty (channel-less /
misconfig) the agent does NOT guess — it opens an escalation case (capturing the question + origin) and
routes to a human. `service` maintenance is scoped to the equipment brand and offers an alternative +
case instead of dead-ending on the coffee brand.

> Brand only stamps on a **real channel MessagingSession**. Preview/SCRT sessions are channel-less, so
> `brand` is empty there — inject it as a context variable when testing headless.

---

## 4. Free rich context — `Customer_Brief__c` (the Flex-credit win)

A signed-in shopper's entire **read** path costs **zero Flex Credits**. Instead of calling
`get_agent_context` / `get_order_status` / `get_maintenance_visits` / `get_subscriptions` live, the
agent reads a pre-stamped brief:

```
(async, off-chat)  DataCloudAugmentationService → materializes DC fields onto each Account
   │
(session before-insert)  MessagingSessionBrandStamp.stamp()
   → resolves PersonEmail → Account
   → CustomerBriefBuilder.briefsByAccount() assembles, bulk-safe, from CRM:
        PROFILE (segment/LTV/brands/multi-brand/churn)
        LAST ORDER (#, status, total, tracking) + OrderItems
        OPEN CASES, upcoming SERVICE VISITS (ServiceAppointment), SUBSCRIPTIONS (Asset)
   → writes MessagingSession.Customer_Brief__c (LongTextArea 32k)
   │
(linked var)  sessionContext ← MessagingSession.Customer_Brief__c
   │
agent: ANSWER read-only questions directly from sessionContext; call a live action ONLY to ACT
       (return/cancel/reship/book/amend) or when the brief lacks the detail.
```

Proven brief (alexkwitko): `PROFILE: segment VIP; LTV ~$3352; brands: Bean & Brew; Kwitko Coffee;
MULTI-BRAND; churn tier C. | LAST ORDER #00000745 Draft — Bean & Brew Pro Espresso Machine x1,
...Installation x1 | SERVICE VISITS: Field Service Appointment Scheduled 6/17/2026`.

Only the **OTP-verify-mid-chat** case still spends the one `get_agent_context` action (identity arrives
after the session — and the linked var — already resolved).

Key components: `MessagingSessionBrandStamp.cls`, `CustomerBriefBuilder.cls`,
`MessagingSession.Customer_Brief__c`, `MessagingSession.Brand__c`.

---

## 5. Identity gate (security)

Verification is a **gate on a verified variable, never a user claim**. `loggedInEmail` (linked,
un-spoofable) means signed in; otherwise a guest must pass an OTP that returns an opaque proof
(`otpVerifiedEmail`). Protected actions require `verifiedEmail`; the Apex refuses without it.
Subscriptions use `Sub*Web` wrapper classes that also enforce **ownership** (anti-IDOR).

Anti-hallucination: the agent may assert an outcome ONLY if the matching action returned
`success=true` this turn — enforced in two layers (Apex returns a flag; instructions bind the claim
to it).

---

## 6. Hard-won gotchas

- **Metadata-deployed fields have NO FLS** → SOQL "No such column", `describe`/`FieldDefinition` show
  it absent — that is the **FLS symptom, not a missing field**. Grant FLS (permset `fieldPermissions`)
  before concluding it didn't deploy.
- **MessagingSession** custom fields: LongTextArea **does** work (the apparent rejection was FLS
  masking). A new Apex class needs its `.cls-meta.xml` or deploy fails "No source-backed components".
- Agent **variable `description` max = 255 chars** — longer makes `sf agent publish` fail
  "data value too large".
- `when` is a **reserved** Apex identifier.
- `sf agent publish` does NOT activate, and `sf agent activate` with no `--version` can pick an OLDER
  version → always `activate --version <highest>` and confirm the active version.
- `start_agent <name>:` keyword invokes the router; it runs first at session start, NOT every turn.

---

## 7. Open / next

- **Transcript persistence via trigger (TODO):** move chat-transcript saving off the agent action onto
  an after-update trigger on `MessagingSession.Status = 'Ended'` that assembles `ConversationEntry`
  (`Message`/`ActorType`/`EntryTime` by `ConversationId`) and writes `Lead.Chat_Summary__c` + the
  linked Case — zero Flex. Model confirmed; not yet built.
- **Real-session verification:** brand + brief only stamp on a real channel `MessagingSession` (0 exist
  yet — all traffic has been channel-less preview). One real web chat is needed to verify the
  channel → field → linked-var chain end to end.
