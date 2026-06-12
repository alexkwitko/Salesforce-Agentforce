# Kwitko Concierge — COMPLETE Service Agent Process Catalog

Every service case, fully mapped: **Trigger · Identity tier · Data + source · Action(s) + outcome flag ·
ALL outcomes · Confirm? · Coverage**. Contract: the agent states an outcome ONLY if the action returned
its success flag THIS turn; every branch ends in a real result or an honest decline + escalation Case.
Coverage key: ✅ built · 🔧 to build · 📚 knowledge/RAG · ⤴ escalate-only (no action yet).

---

## 0. IDENTITY GATE (precondition for everything that touches an account)
- **Tier 1 — logged-in pass-through:** `loggedInEmail` present → verified, zero friction.
- **Tier 2 — email OTP:** ask account email → `request_verification_code` → emails 6-digit, ≤10-min, one-time code → `verify_code` → verified for session. Works when they CAN'T log in. 🔧
- **Tier 3 — step-up:** fresh OTP before changing email/phone or refund over cap.
- **Rule:** until verified, reveal NOTHING and run NO gated action. "I'm signed in" alone ≠ verified.
- Outcomes everywhere below: **NV** = not verified → run identity gate; if it fails 3× → escalate Case.

---

## A. ORDER & DELIVERY

### A1. Order status  ✅
- Trigger: "where's my order / order status / what did I buy"
- Identity: required · Data: `Order` (Fulfillment_Status__c, items, total, dates) — SF (Woo-synced)
- Action: `get_order_status` → flag `found`
- Outcomes: **found** → show order#, items, status, canCancel/canReturn · **not found** → say so, offer another email · **NV** · **error** → open Case
- Confirm: no (read-only)

### A2. Tracking / "where is it"  ✅
- Trigger: "track my package / tracking number"
- Identity: required · Data: `Tracking_Number__c`, `Carrier__c`, `TrackingUrl` — SF Order (Woo carrier sync)
- Action: `get_tracking` → flag `found`
- Outcomes: **found** → carrier + number + link + ETA · **not shipped yet** → "still being prepared, no tracking yet" · **no order** · **NV** · **error**→Case
- Confirm: no

### A3. Order never arrived (lost)  ✅
- Trigger: "never arrived / didn't get it / lost"
- Identity: required · Data: order + tracking (A1/A2)
- Action: `get_order_status`+`get_tracking`; if unresolved → `open_case(Shipping, escalate)`; optional `reship`
- Outcomes: **in transit & within ETA** → set expectation, offer Case if still worried · **carrier=delivered but denied** → confirm address, offer reship or delivery-dispute Case · **overdue/lost** → CONFIRM → open Case (caseNumber) and/or reship(success) · **NV** · **no order**
- Confirm: yes for reship (money/goods)

### A4. Arrived damaged  ✅ (reship/return/credit) 
- Trigger: "arrived broken/damaged/leaking"
- Identity: required · Data: order (must be delivered)
- Action: choose with shopper → `reship` (free replacement) OR `process_return` (refund) OR `apply_store_credit` (goodwill ≤$50); always `open_case(Quality)` for traceability
- Outcomes: **replacement** reship.success → replacementOrderNumber+caseNumber · **refund** process_return.success → returnOrderNumber+refundAmount · **credit** apply_store_credit.success → code · **not delivered yet** → not eligible, set expectation · **NV** · **error**→Case
- Confirm: yes (money/goods)

### A5. Wrong / missing items  ✅ (reship missing + case)
- Trigger: "got the wrong roast / item missing from box"
- Identity: required · Data: order items (`itemsSummary`)
- Action: confirm which items wrong/missing → `reship` the correct/missing items + `open_case(Fulfillment)`
- Outcomes: **reship.success** → replacement order# + case# · **item not matched** → re-show items, re-ask · **NV** · **error**→Case
- Confirm: yes

### A6. Delivery delayed / late  ✅
- Trigger: "it's late / taking too long"
- Identity: required · Data: tracking + ETA
- Action: `get_tracking`; if past ETA → offer `open_case` or `apply_store_credit` (goodwill)
- Outcomes: **in transit** → real ETA, reassure · **past ETA** → CONFIRM → Case and/or goodwill credit · **NV**
- Confirm: yes for credit

---

## B. RETURNS / REFUNDS / EXCHANGES

### B1. Return for refund  ✅
- Trigger: "return / refund / send it back / changed mind"
- Identity: required · Data: order (must be DELIVERED → `canReturn`)
- Action: `get_order_status` (SHOW order+items first) → `process_return(itemsToReturn, reason, confirmed)` → flag `success`/`refundIssued`
- Outcomes: **canReturn=false** → quote real status, refuse, offer track/case · **success** → returnOrderNumber + refundAmount + returnTracking IN CHAT · **item unmatched** → re-ask · **refused by rule** (window) → relay, offer goodwill/case · **no order** · **NV** · **error**→Case
- Confirm: YES (issues refund)

### B2. Exchange (different product)  ✅
- Trigger: "swap for a different coffee"
- Action: `process_exchange(itemsToExchange, desiredItem, confirmed)` → `success` (returns original + opens exchange case)
- Outcomes: **success** → caseNumber + what's coming · **not delivered/eligible** → refuse · **NV** · **error**→Case · Confirm: YES

### B3. Free replacement / reship (same item)  ✅
- Trigger: "just send me another one"
- Action: `reship(itemsToReplace, confirmed)` → `success`
- Outcomes: **success** → replacementOrderNumber + caseNumber · **not matched** → re-ask · **NV** · **error**→Case · Confirm: YES

### B4. Partial return (some items)  ✅
- Same as B1 with `itemsToReturn` = the chosen subset (agent lists items, shopper picks). Outcomes per B1; refund = sum of selected items.

### B5. Refund status / "where's my refund"  ✅ (via order status) / ⤴ if dispute
- Trigger: "did my refund go through"
- Action: `get_order_status` (returnStatus / refunded note); if customer says not received → `open_case(Billing)`
- Outcomes: **refunded per record** → relay date/amount · **pending** → relay status + typical timing · **claims not received** → Case · **NV**

### B6. Return window expired / non-returnable  ✅ (Apex refuses)
- Action: `process_return` returns refusal message → relay it honestly; offer goodwill credit or Case. NEVER override silently.

---

## C. CANCELLATIONS & ORDER CHANGES

### C1. Cancel order  ✅
- Trigger: "cancel my order"
- Identity: required · Data: order (`canCancel` = not yet shipped)
- Action: `cancel_order(confirmed)` → `success`/`refundIssued`
- Outcomes: **canCancel=false (shipped)** → refuse, offer return-on-arrival · **success** → message + refundAmount + caseNumber · **NV** · **error**→Case · Confirm: YES

### C2. Change shipping address (pre-ship)  ✅
- Action: `update_shipping_address(...confirmed)` → `success`
- Outcomes: **updated** · **already shipped** → refuse, offer carrier reroute/Case · **NV** · **error**→Case · Confirm: YES · Tier-3 if it's a contact-detail change

### C3. Modify items / quantity (pre-ship)  ✅
- Action: `modify_order(change, confirmed)` → `success`
- Outcomes: **changed** · **already shipped** → refuse · **NV** · **error**→Case · Confirm: YES

### C4. Reschedule / hold delivery  ⤴
- No carrier-reschedule action. → `open_case(Shipping)` + tell them honestly a human/carrier will handle; offer tracking.

---

## D. BILLING & PAYMENT

### D1. Failed payment  ✅
- Trigger: "my payment failed / card declined"
- Action: `handle_failed_payment` → returns secure pay-now link
- Outcomes: **link** → relay link (never take card in chat) · **no failed order** → clarify · **NV** · **error**→Case

### D2. Double charged / overcharged  ⤴ (Case)
- Action: `open_case(Billing, escalate, chatSummary)` → caseNumber. Agent does NOT reverse charges itself. Outcomes: case# + human follow-up · **NV**

### D3. Refund not received  → see B5 → `open_case(Billing)` if past expected window.

### D4. Receipt / invoice request  ⤴ (Case) or 📚
- Action: `open_case(Billing, "send receipt")` (no dedicated action) → caseNumber. (Future: email-receipt action.)

### D5. Coupon / discount not applied  ✅/⤴
- Action: if eligible, `issue_coupon` (or relay `activeCouponCode` from context); else `open_case`. NEVER invent a discount. Confirm: n/a

---

## E. ACCOUNT & LOGIN  (Tier-2 OTP is the unlock — they often can't log in)

### E1. Login issue  🔧 (needs OTP)
- Trigger: "can't log in"
- Identity: Tier-2 OTP (do NOT require website login — that's the problem)
- Action: diagnose → usually `password_reset_link`; if blocked → `open_case(Account, escalate)`
- Outcomes: **reset sent** · **needs human** → Case · **OTP fails 3×** → Case · **error**→Case

### E2. Password reset  ✅ action / 🔧 gate
- Action: `password_reset_link(email)` after Tier-2 verify → `success`
- Outcomes: **sent** → "reset link sent to <email>" (+dev spam note) · **no account** → Case · **NV**

### E3. Update email / phone on file  🔧 (Tier-3 step-up) / ⤴
- Requires FRESH OTP (step-up). No dedicated action yet → `open_case(Account)` with verified request, or build `update_contact`. Never change contact details without step-up.

### E4. Update payment method  ⤴
- Security: don't collect card in chat. → `handle_failed_payment` pay-link (re-enters card on hosted page) or `open_case(Billing)`.

---

## F. PRODUCT & POLICY (knowledge — no account needed)

### F1. Product question (origin, roast, caffeine, tasting, brew)  📚
- Source: Data Library RAG / Product2 structured attrs. Answer from grounded content ONLY; if unknown → say so, offer Case/human. No identity needed.

### F2. Policy / shipping times / returns policy / hours  📚
- Answer from grounded policy content; never invent a policy. Unknown → escalate.

### F3. Stock / restock / "do you have X"  📚/⤴
- Relay catalog availability; restock requests with no action → `open_case` or capture interest. 

### F4. Recommendation / "what should I buy"  ➡ hand to **shopping** subagent (out of service scope).

---

## G. SUBSCRIPTIONS  ⤴ (NOT in current build)
Pause / skip / cancel / change frequency / swap product / change next date. **No subscription model or
actions exist today.** → treat as NOT COVERED: honest decline + `open_case(Account, "subscription change")`
or callback. (Future: build subscription objects + actions, then promote these to ✅.)

---

## H. HUMAN / COMPLAINT / FEEDBACK

### H1. Complaint / "this is unacceptable"  ✅
- Action: empathize → fix if possible (credit/refund/reship within caps) → `open_case(escalate)` with full chatSummary → caseNumber.

### H2. "Talk to a human"  ✅
- Action: `open_case(escalate=true)` and/or `schedule_callback` → give caseNumber / callback confirmation.

### H3. Callback request  ✅
- Action: `schedule_callback(reason, preferredTime)` → success → confirm when a human will call.

### H4. Feedback / praise  ⤴/log
- Thank them; log via `open_case(category=Feedback)` or journey note. No fabrication.

---

## I. NOT COVERED — the universal catch-all (kills hallucination at the edges)
If a request maps to NO capability above, OR an action errors with no recovery:
1. Say plainly: "I can't do that directly."
2. `open_case(category, subject, escalate=true, chatSummary=<faithful full transcript>)`.
3. Give the `caseNumber` + that a human will follow up; offer `schedule_callback` if phone fits.
**NEVER** invent an outcome, promise an email/refund/case you didn't create, or proceed unverified.

---

## J. What must be BUILT to make this fully real (deltas)
- 🔧 OTP: `request_verification_code` + `verify_code` + `IdentityService` (logged-in OR session-OTP) — unlocks E1/E2 + Tier-2 everywhere.
- 🔧 Rewrite service `reasoning` straight from this catalog (one explicit branch per outcome; identity gate as step 0; remove any "trust I'm signed in" path).
- 🔧 Tier-1 fast path: finish prechat→`loggedInEmail` delivery.
- ⤴→✅ later: contact-detail update (E3), receipt email (D4), subscriptions (G).
- Tests: one per outcome leaf, especially the negatives (NV, not-eligible, errored→Case).
- Prod-only: real sending domain / SMS for inbox OTP (NOT a dev blocker).
