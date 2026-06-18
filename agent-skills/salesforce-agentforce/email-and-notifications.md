# Email & notifications from agents/Apex (product-agnostic)

How an Agentforce solution actually gets a message to a person — and the limits/gotchas that decide whether it arrives. Applies to any domain (commerce, FSI, healthcare, B2B).

## First decision: transactional vs marketing — they route differently
- **Transactional / service** (OTP codes, password help, order/claim/appointment confirmations, return labels): no marketing consent required, must be immediate. Send from **Salesforce** (Apex `Messaging.sendEmail`, or a notification action). This is fine to keep in-platform.
- **Marketing / nurture / promotional**: consent REQUIRED, deliverability + unsubscribe + throttling matter. In a real org these go through the **marketing send engine (Marketing Cloud Engagement/Growth)**, NOT Apex. See `consent-and-marketing-activation.md`.

Design rule: **agents and Apex should *trigger* marketing sends (enroll in a journey / nominate into a segment), not *be* the mail server.** Reserve direct Apex email for transactional.

## ⭐ The daily email cap is method-dependent — `setTargetObjectId` is EXEMPT
Salesforce caps **single emails to EXTERNAL addresses** per 24h (Developer Edition = **15/day**; higher in paid editions). The trap: this cap only counts emails sent with **`setToAddresses`** (raw address strings). Emails sent to a **Lead / Contact / Person Account / User record** via **`setTargetObjectId` do NOT count against the cap at all.**

So the fix for "Email limit exceeded" is almost never a new email provider — it's sending to the *record* instead of the *address*:
```apex
Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
if (targetId != null) {              // Lead/Contact/User id (Person Account -> its PersonContactId)
    m.setTargetObjectId(targetId);   // CAP-EXEMPT
    m.setTreatTargetObjectAsRecipient(true);
} else {
    m.setToAddresses(new List<String>{ rawEmail });   // counts against the daily cap
}
m.setSubject(s); m.setHtmlBody(b); m.setSaveAsActivity(false);
if (oweaId != null) m.setOrgWideEmailAddressId(oweaId);
```
Notes:
- `setTargetObjectId` sends to the *record's* Email field (so keep the record's email accurate); for a **Person Account** use its `PersonContactId` (a Contact), not the Account id; for `Account` business records there's no single recipient — fall back to `setToAddresses`.
- It still honors the recipient's `HasOptedOutOfEmail` — fine, that's consent-correct.
- Verify the exemption empirically: read `/limits` → `SingleEmail.Remaining` before/after a send; with `setTargetObjectId` it does **not** decrement.
- Works with a verified Org-Wide Email Address (OWEA) for branding.

## Deliverability: From-address / DMARC (the other reason mail "sends" but doesn't arrive)
`Messaging.sendEmail` returns `isSuccess=true` yet the mail is dropped when the From is a freemail/unowned domain (`@gmail.com`, etc.) OWEA — the recipient's DMARC rejects "from gmail.com relayed by Salesforce." (Gmail-to-the-org's-own-gmail can still arrive, masking the problem in demos.)
- **Real fix:** OWEA on a domain you control + SPF + Salesforce DKIM (Setup → Email → DKIM Keys) in DNS.
- **DE/no-domain reality:** a verified freemail OWEA often DOES deliver to ordinary recipients (it's how OTP arrives); the **only** hard limit there is the daily cap — which `setTargetObjectId` removes. So you can get a working transactional path on a DE org with zero new infrastructure.

## ⚠️ Anti-pattern: bolting a non-Salesforce relay onto the org to "send from Gmail"
Tempting hack when capped: route Salesforce → an external site (e.g. WordPress) → that site's mailer. Why it usually fails:
- The external site's **default mailer (shared host PHP mail) has no SPF/DKIM** for its domain → the mail returns "ok" but lands in spam / is dropped (same DMARC problem, different host).
- Authenticated SMTP there (e.g. Gmail SMTP via an SMTP plugin) needs **either an OAuth/API app or an app password** — friction the customer may not have, and it's a second consent/deliverability system to maintain.
- It splits sending across two systems and bypasses Salesforce consent/activity logging.
Before building a relay, exhaust the in-platform options: **`setTargetObjectId` (cap), DKIM domain (deliverability), or the marketing send engine (scale).** A relay is a Frankenstein — see the #0 rule in `SKILL.md`.

## Consent-gate every marketing send in ONE shared service
Don't scatter consent checks. Funnel marketing email through a single `@InvocableMethod` "send" service that re-checks consent from the related record (or, better, the Data Cloud effective consent) right before sending, and refuses otherwise. Agents call this one action; they never construct raw sends. (Transactional messages pass an `isTransactional=true` flag that skips the marketing-consent gate.)

## Async when the caller has done DML
An HTTP-callout-based send (e.g. to a marketing API or an external relay) **cannot run after DML in the same transaction** ("uncommitted work pending"). Enqueue a `Queueable implements Database.AllowsCallouts` so the callout runs in its own transaction. (Native `Messaging.sendEmail` is not a callout and is exempt, but a `setTargetObjectId` send after DML is still fine.) In tests, guard the enqueue/callout (`Test.isRunningTest()`), or chaining from an async context throws.

## Quick triage
1. "Email limit exceeded" → send via **`setTargetObjectId`** (record), not `setToAddresses`. Don't add a provider.
2. `isSuccess=true` but not received → **DMARC/From domain** (DKIM) or it's marketing going to spam → use the marketing engine.
3. Marketing at scale / journeys / unsubscribe → **Marketing Cloud**, triggered by Agentforce/Data Cloud (see `consent-and-marketing-activation.md`).
4. "uncommitted work pending" on send → make the callout **async (Queueable)**.
