# Service Agent Design — Kwitko Concierge Web (process → outcome → action)

Built from `Kwitko_Concierge_Web-discovery.md` per the `salesforce-agentforce` skill methodology.
**Contract:** the agent asserts an outcome ONLY if the named action returned its success flag IN THIS
TURN. Every leaf ends in a real action result or an honest "I can't" + escalation Case. No exceptions.

---

## 0. Identity gate — the precondition for EVERY service action
Identity is a GATE on a verified value, never a user's claim. Resolve the tier ONCE, early, then reuse.

```
IDENTITY RESOLUTION (run before any data read or action)
 ├─ Tier 1: loggedInEmail present?  (MessagingSession.Kwitko_Logged_In_Email__c → ctx var)
 │     └─ yes → VERIFIED (verifiedEmail = loggedInEmail). Proceed.
 ├─ Tier 2: ask for account email → request_verification_code(email)
 │     → "I emailed a 6-digit code to <email>, what is it?" → verify_code(email, code)
 │     ├─ verified=true  → VERIFIED for session. Proceed.
 │     ├─ expired/wrong  → retry up to 3, then escalate (R-NV)
 │     └─ no account for email → say so, offer to try another email or escalate
 └─ Tier 3 (step-up): before change-email/phone or refund > cap → require a FRESH verify_code first.
GLOBAL RULE: until VERIFIED, reveal NOTHING (no order, address, tracking, PII) and run NO gated action.
"I'm signed in" with empty loggedInEmail = NOT verified → go to Tier 2.
```
- **New build:** `request_verification_code` / `verify_code` Apex actions; `IdentityService.isVerified`
  extended to accept (logged-in email) OR (confirmed session OTP). Code = 6-digit, ≤10-min expiry,
  one-time, hashed at rest (Platform Cache or `Verification__c` keyed to the conversation).
- Every gated action keeps receiving `verifiedEmail` = the resolved verified email.

## 1. Capability map (in-scope v1) — every capability has ONE backing action + an outcome flag
| Capability | Action | Outcome flag (truth) | Precondition | Money/data |
|---|---|---|---|---|
| Order status | `get_order_status` (OrderStatusService) | `found` | verified | read |
| Tracking | `get_tracking` (TrackingService) | `found` | verified | read |
| Order never arrived | `get_order_status`+`get_tracking` → `open_case` | `found` / `caseNumber` | verified | read→log |
| Return + refund | `process_return` (ReturnService) | `success` (+`refundIssued`) | verified + `canReturn` + confirm | refund |
| Free replacement | `reship` (ReshipService) | `success` | verified + confirm | goods |
| Exchange | `process_exchange` (ExchangeService) | `success` | verified + delivered + confirm | goods/refund |
| Cancel | `cancel_order` (CancellationService) | `success` (+`refundIssued`) | verified + `canCancel` (pre-ship) + confirm | refund |
| Address change | `update_shipping_address` | `success` | verified + pre-ship + confirm | data |
| Failed payment | `handle_failed_payment` | `success`/link | verified | pay-link |
| Billing/payment problem | `handle_failed_payment` or `open_case` | flag/`caseNumber` | verified | link/log |
| Login issue / pw reset | `password_reset_link` | `success` | verified (Tier-2 OTP) | link |
| Store credit (goodwill) | `apply_store_credit` | `success` (≤$50 cap) | verified + confirm | credit |
| Case / escalation | `open_case` (CaseService) | `caseNumber` | verified (guest ok for generic) | log |
| Resolve case | `resolve_case` | `success` | verified | log |
| Callback | `schedule_callback` | `success`/case | verified | log |
| Shared context | `get_agent_context` | `identityVerified`,`mustAskForSignIn` | — | read |
> A capability with no action = agent CANNOT do it → **not covered → escalate** (§ last).

## 2. Per-process outcome matrices + decision trees

### 2.1 Order status / tracking
Outcomes: S1 found+shown · S2 no order found · S3 not verified · S4 action error.
```
verify → get_order_status (this turn; no "one moment")
 ├─ found=false → S2 "No order found for <email>." offer recheck/another email
 ├─ found=true  → S1 relay @summary, items, fulfillmentStatus, canCancel/canReturn; if shipped add tracking
 └─ error/no flag → S4 apologize + open_case (DO NOT invent a status)
```

### 2.2 "My order never arrived"  (carrier-status-first, then case)
Outcomes: N1 in-transit (not late) · N2 delivered-per-carrier but customer says no · N3 lost/overdue → case ·
N4 not verified · N5 no order.
```
verify → get_order_status (+ get_tracking)
 ├─ found=false → N5
 ├─ status in transit & within ETA → N1 show carrier+tracking+ETA, set expectation, offer case if still worried
 ├─ carrier says DELIVERED but customer denies → N2 confirm address, offer reship OR open_case (delivery dispute)
 └─ overdue / no movement / lost → N3 CONFIRM, then open_case(category=Shipping, escalate) → give caseNumber;
        optionally offer reship (free replacement, confirm) — only claim it if reship.success=true
```

### 2.3 Return / refund / exchange / reship
Outcomes: R1 success · R2 not-eligible (not delivered) · R3 not verified · R4 no order · R5 item not matched ·
R6 refused by Apex (window/rule) · R7 error.
```
verify → get_order_status → SHOW order# + items + status
 ├─ found=false → R4
 ├─ canReturn=false → R2 quote real status ("00000731 is Shipped, not delivered yet — not returnable until it arrives"); offer track/case. STOP.
 └─ canReturn=true → ASK which items (list itemsSummary) + refund? replacement? exchange?
        → CONFIRM "Return <items> from <order#>, refund <amount>?"  (mandatory, money-moving)
        → refund: process_return(confirmed=true)
              ├─ success=true → R1 state returnOrderNumber + refundAmount + returnTracking IN CHAT
              ├─ item unmatched → R5 re-show items, re-ask
              ├─ refused → R6 relay message; offer goodwill/case
              └─ error → R7 open_case, never claim success
        → replacement: reship(itemsToReplace, confirmed=true) → success → state replacementOrderNumber+caseNumber
        → exchange: process_exchange(itemsToExchange, desiredItem, confirmed=true) → success → state caseNumber
```

### 2.4 Cancel order
Outcomes: C1 success+refund · C2 not-eligible (already shipped) · C3 not verified · C4 no order · C5 error.
```
verify → get_order_status
 ├─ canCancel=false → C2 "Order has shipped, can't cancel — you can refuse/return on arrival." offer return path
 └─ canCancel=true → CONFIRM → cancel_order(confirmed=true)
        ├─ success=true → C1 relay message + refundAmount + caseNumber
        └─ error → C5 open_case
```

### 2.5 Address change (pre-ship)
A1 updated · A2 too late (shipped) · A3 not verified · A4 error → all via update_shipping_address flag; if shipped, refuse + offer carrier-reroute/case.

### 2.6 Billing / payment problem
B1 failed-payment → handle_failed_payment returns secure pay-now link (relay it) · B2 other billing dispute → open_case(category=Billing) + caseNumber · B3 not verified · B4 error→case. Agent NEVER takes card details in chat.

### 2.7 Login issue / password reset  (Tier-2 OTP is the unlock — they often can't log in)
L1 reset sent · L2 needs human · L3 verify failed · L4 error.
```
verify via Tier-2 email OTP (do NOT require website login — that's the problem)
 ├─ OTP verified → password_reset_link(email) → success=true → L1 "Reset link sent to <email>." (+spam note in dev)
 ├─ OTP fails 3x / no account → L2 open_case(category=Account, escalate) → human
 └─ error → L4 open_case
```

### 2.8 Cases / callbacks / escalation
E1 case opened (give caseNumber, transcript attached) · E2 callback scheduled · E3 case resolved (resolve_case). open_case MUST always carry a faithful chatSummary.

## 3. Global rules baked into every branch
1. **Anti-hallucination:** assert "<done>" only if the action returned its success/created flag THIS turn. No "it'll arrive shortly" for an action you didn't call.
2. **Confirm before money/data moves:** return, refund, cancel, credit, reship, address change.
3. **Relay, don't invent:** statuses/tracking/amounts/case numbers come only from `@outputs`.
4. **PII discipline:** nothing read back before VERIFIED; step-up before changing contact details.
5. **Make it right > just log:** prefer real fixes (refund/credit/reship/resolve) over only opening a case — within caps.

## 4. NOT COVERED → escalate (never improvise)
If the request maps to no capability above, OR an action errors with no recovery:
say plainly "I can't do that directly," call `open_case(category, subject, escalate=true, chatSummary=<full transcript>)`,
give the `caseNumber`, and tell them a human will follow up (offer `schedule_callback` if phone is better).
NEVER fabricate an outcome to seem helpful.

## 5. Build deltas to implement (from this design)
- [ ] **OTP:** `request_verification_code` + `verify_code` Apex actions + `Verification__c`/Platform Cache; extend `IdentityService.isVerified` (logged-in OR session-OTP).
- [ ] **Identity gate in prompt:** rewrite the service subagent `reasoning` so step 0 is the tier resolution above; remove any path that proceeds on "I'm signed in" with empty `loggedInEmail`.
- [ ] **Rewrite service reasoning from §2 trees** (one explicit branch per outcome incl. R2/R4/R7 etc.); wire OTP + login/password as first-class flows.
- [ ] **Tier-1 fast path:** finish the prechat→`loggedInEmail` delivery (separate task) so signed-in users skip OTP.
- [ ] (Prod only) email sending domain / SMS for inbox-deliverable OTP — NOT a dev blocker.

## 6. Verification matrix (prove every leaf, esp. the negatives)
For each outcome (S/N/R/C/A/B/L/E) one test: `sf agent test` (expectedActions + real side effect) and/or an Apex test of the action flag, plus a live smoke for headline paths. **Must explicitly prove:** not-verified reveals nothing (S3/R3/L3); not-eligible refuses (R2/C2/A2); errored action opens a case instead of faking (S4/R7/C5). Mind the AI-Evaluation storage hog (troubleshooting.md).
