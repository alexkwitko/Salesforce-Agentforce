# Discovery Brief — Kwitko Concierge Web (Service side)

Produced via the `salesforce-agentforce` skill discovery process (discover → design → build → deploy → verify).
This brief is the confirmed input to `Kwitko_Concierge_Web-service-design.md` (process/outcome/decision trees).

## A. Business & the agent's job
- **Business:** Kwitko Coffee Co. — specialty-coffee e-commerce, WooCommerce storefront, Salesforce = system of record.
- **Agent:** `Kwitko_Concierge_Web` — MIAW WebV2 Service Agent (`ExternalCopilot`) in the storefront chat; handles BOTH shopping and **service**. This brief covers the **service** subagent.
- **One job (service):** resolve post-purchase + account issues in chat — status/tracking, not-arrived, returns/refunds/exchanges, cancellations, address/payment fixes, **login & password help**, billing problems — and when it can't, escalate honestly.
- **Success:** the shopper gets a real, truthful outcome (a real status, a real refund/case/credit with a number) — and the agent NEVER claims an outcome that didn't happen.
- **Red lines:** no hallucinated actions; no PII or account action before identity is verified; confirm before money moves.

## B. In-scope processes (v1) — confirmed by owner
1. Order status & tracking
2. "Order never arrived" → check carrier/shipping status first, then open a case if needed
3. Returns / refunds / exchanges (+ free replacement / reship)
4. Cancel order (pre-ship)
5. Cases, callbacks, shipping-address fixes
6. Password reset
7. Login issues
8. Billing / payment problems
> Anything else → **not covered → escalate** (open case + honest decline).

## C. Identity / authentication model — DECIDED
The customer is frequently UNauthenticated (login/password help is in scope — they're chatting BECAUSE they can't log in).
So identity cannot depend on being logged in. Model (research-backed: Shopify/LoginRadius/Descope service-desk guidance — root of trust = control of the email/phone on file, verified by a time-limited one-time code; NOT order numbers, NOT passwords):
- **Tier 1 — logged-in pass-through (fast path):** verified sign-in email reaches the agent → already verified, zero friction. *(Requires fixing the prechat→MessagingSession `loggedInEmail` delivery — see prerequisites.)*
- **Tier 2 — email OTP (universal fallback):** ask for the account email → email a 6-digit, time-limited, one-time code → shopper reads it back → verified for the session. No password / no order number; works for can't-log-in cases.
- **Tier 3 — step-up:** require a fresh OTP before high-risk actions (change email/phone on file, large refunds).
- **Hard rule:** reveal nothing / do nothing until ≥ Tier 2 passes. "I'm signed in" is NEVER accepted on its own.

## D. Not-covered / failure behavior — DECIDED
Open an escalation **Case** with the full chat transcript, tell the shopper honestly it can't do that directly, give the case number + that a human will follow up. Never fake success. (Callback is also available where phone follow-up fits.)

## E. Fix authority — DECIDED
Agent may execute money-moving fixes (refund, store credit, free reship) **autonomously AFTER explicit shopper confirmation, with hard Apex caps** (goodwill credit ≤ $50; refund only on eligible delivered orders; cancel only pre-ship). Higher-risk → step-up or human case.

## F. Data & systems inventory (verified in org 2026-06-08)
| Need | System / object | API names | How accessed | Source of truth | Verified |
|---|---|---|---|---|---|
| Order + fulfillment + tracking | SF `Order` (Woo-synced) | `Fulfillment_Status__c`, `Tracking_Number__c`, `Carrier__c`, `Last_Woo_Sync__c` | Apex `OrderStatusService` / `TrackingService` | SF Order (fed by Woo carrier info via FulfillmentTruthService) | ✅ 00000731 fresh, synced today 15:45 |
| Identity / context gate | `AgentContextService` | returns `identityVerified`, `safeToUsePrivateContext`, `mustAskForSignIn` | Apex action `get_agent_context` | central gate | ✅ exists |
| Returns | `ReturnService` → ReturnOrder | `success`, `returnOrderNumber`, `refundAmount`, `refundIssued`, `returnTracking`, `itemsReturned`, `message` | Apex action `process_return` | SF | ✅ |
| Reship / Exchange | `ReshipService` / `ExchangeService` | success/order#/case#/message | `reship` / `process_exchange` | SF | ✅ |
| Cancel | `CancellationService` | `success`, `orderNumber`, `refundIssued`, `refundAmount`, `caseNumber`, `message` | `cancel_order` | SF | ✅ |
| Cases | `CaseService` → Case | `success`, `caseNumber`, `caseId`, `message` | `open_case` | SF | ✅ |
| Tracking | `TrackingService` | `found`, `trackingNumber`, `carrier`, `trackingUrl`, `message` | `get_tracking` | SF Order | ✅ |
| Address / payment / callback / pw-reset | AddressUpdateService / PaymentService / CallbackService / password_reset_link | per-action `success`/`message` | respective actions | SF/Woo | exists |
| Customer history | `CustomerLookupService` (+ Data Cloud) | `isReturning`, `orderCount`, `preferences`, `openCaseCount`, `activeCouponCode`… | `lookup_customer` | SF + Data Cloud | ✅ |

## G. Channel & entry point
- MIAW WebV2 embedded chat on the WooCommerce storefront (Hostinger). Entry = chat launcher on every page.
- Routing: Omni-Channel Flow `Kwitko_Web_Chat_Routing` → Route Work → this Service Agent.
- Logged-in email intended via hidden pre-chat → `MessagingSession.Kwitko_Logged_In_Email__c` → Bot context var `loggedInEmail`. **Currently not arriving (Tier 1 broken) — prerequisite below.**

## H. PREREQUISITES (must be true before the model fully works) — NEW WORK
1. **Email deliverability** 🟢 DEV: NON-ISSUE — owner decision: this is a dev/test org, sending via gmail OWEA is accepted; OTP codes arrive (may land in spam, fine for dev testing). **PROD-ONLY hardening (not a blocker now):** before go-live, send from a real domain with SPF + Salesforce DKIM + DMARC (or SMS OTP) so codes hit the inbox. Do NOT block the build on this.
2. **Tier-1 fast path** 🟠 — fix prechat→`loggedInEmail` delivery so signed-in shoppers skip OTP. (Investigated extensively: config is correct; the value isn't landing on the MessagingSession field. Candidate fix: have the routing flow write the field, or finish verifying the prechat key live.) Not blocking Tier 2, but needed for the frictionless path.
3. **OTP actions** 🟠 — build `request_verification_code(email)` + `verify_code(email, code)` Apex (hashed code + expiry in Platform Cache or a `Verification__c` record keyed to the conversation); extend `IdentityService.isVerified` to accept EITHER logged-in email OR a confirmed session OTP.

## Hand-off
→ `Kwitko_Concierge_Web-service-design.md`: capability map, per-process outcome matrix, and decision trees built from the above. Every leaf ends in a real action result or an honest "can't" + escalation; the agent asserts an outcome only when the action returned its success flag this turn.
