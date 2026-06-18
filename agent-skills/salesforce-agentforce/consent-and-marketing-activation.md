# Consent management & marketing activation (Data Cloud + Agentforce + Marketing Cloud)

How a real connected Salesforce shop unifies consent across many source apps and sends marketing the supported way — with Agentforce as the *decisioning* layer, not the mail server. Product-agnostic.

## The separation of concerns (memorize this)
> **Agentforce decides. Data Cloud unifies + enforces consent + segments. Marketing Cloud sends.**

| Layer | Owns | Does NOT do |
|---|---|---|
| **Sales/Service Cloud + Agentforce** | System of record; lifecycle status; reasoning, next-best-action; *nominating* a person into a segment / *enrolling* in a journey | Send marketing email; hold the recipient list; decide consent |
| **Data Cloud** | Unified profile (Identity Resolution); the **consent model**; segments; **consent-aware activation** | Send the email itself |
| **Marketing Cloud Engagement/Growth** | Journeys, the actual send, **deliverability (SPF/DKIM/DMARC)**, unsubscribe, throttling, A/B, analytics | Decide who's eligible (that's the segment/activation) |

A standalone Agentforce/Apex org (no Marketing Cloud) *simulates* the right column with a consent-gated Apex send (see `email-and-notifications.md`) — but the design and the migration target are the same.

## Consent across MANY source apps → ONE effective consent
Each app (storefront, preference center, in-chat capture, POS/mobile, Marketing Cloud itself) has its own consent signal. Don't keep them per-app. **Ingest each into Data Cloud's standard Consent data model**, keyed to the Individual + ContactPoint, each row carrying **source + timestamp**:

| Consent DMO | Granularity | Example |
|---|---|---|
| **Engagement Channel Type Consent** | channel | email / SMS opt-in/out |
| **Communication Subscription Consent** | topic/subscription | "Promotions" yes, "Newsletter" no |
| **Authorization Form Consent** | legal basis + version | agreed to ToS v3 / GDPR basis |
| **Contact Point Consent** | a specific address/number | this email confirmed |

(These are the same Consent Management objects the core platform uses — `ContactPointTypeConsent`, `CommSubscriptionConsent`, `AuthorizationFormConsent`, etc. — so CRM-captured consent and external consent land in one schema.)

**Reconcile to one usable value:** Identity Resolution ties every ContactPoint + consent row to the unified Individual. Then define a **reconciliation policy** (sources disagree): standard practice = **most-recent-by-timestamp wins, opt-out is sticky / most-restrictive wins on conflict.** Implement as a **Calculated Insight** (or native consent reconciliation) that exposes the *effective* per-channel, per-subscription consent on the unified profile. **That effective value is the single thing every send reads** — never the per-app flags.

## Enforce consent at the SEND — in the activation, not in app code
The key architectural move: **consent is a property of the activation/journey, not of whoever triggered it.**
- A Data Cloud **Activation** has a **Consent** section: attach the ContactPoint (e.g. email) + the required channel/subscription consent → the activation **only publishes individuals whose effective consent = granted** (and current auth-form version).
- Marketing Cloud honors **subscriber opt-out** as a second gate.
- Net: consent is enforced **once, centrally**. Every send — journey, agent-triggered, batch, ad audience — inherits it. No code hand-checks a consent flag again.

## The Agentforce → Data Cloud → Marketing Cloud bridge (don't let the agent send)
The common mistake: the agent both *decides* and *sends*. Split it:
1. **Agentforce action writes a decision/signal** — next-best-action + an "enroll/nominate" intent — onto the profile via a **Data Cloud Data Action**, or a CRM field that streams into Data Cloud. It does **not** send.
2. **Data Cloud** turns that signal into **segment membership** (a real-time segment, e.g. "agent-recommended: nurture").
3. **Consent-aware Activation** publishes that segment to **Marketing Cloud**.
4. **Marketing Cloud Journey** sends; engagement (opens/clicks/conversions) flows back to Data Cloud → updates the profile/NBA → loop.

Trigger styles: **batch/near-real-time** (agent sets flag → segment refresh → activation; decoupled, scalable) or **single-record real-time** (agent fires a streaming activation / Journey API entry for one individual — still through the consent gate).

## Connectors (what physically links the layers)
- **Marketing Cloud Connect** — Sales/Service Cloud ↔ Marketing Cloud Engagement: syncs Leads/Contacts/Campaigns, lets Flow/Agentforce trigger a journey, writes send/open/click back as activities.
- **Data Cloud Activation target** — Data Cloud → Marketing Cloud (or ad platforms): publishes a (consent-filtered) segment as a journey audience.
- **Journey entry event** (REST/Flow) — enroll a single individual on demand.

## Edition choice
- **Marketing Cloud Engagement** (classic): Journey Builder + Email Studio + Marketing Cloud Connect. Most common today; B2C high-volume.
- **Marketing Cloud Growth** (newer, native on core + Data Cloud + Flow): emails triggered by Data Cloud segments + Flow directly; tightest Agentforce/Data Cloud fit, least connector glue — where Salesforce is heading.
- **Marketing Cloud Account Engagement (Pardot)**: B2B nurture/scoring.

## Map a no-Marketing-Cloud build onto this (migration)
What a standalone Agentforce org builds as a stand-in, and its enterprise equivalent:
| Stand-in (Apex/Flow) | Enterprise component |
|---|---|
| decisioning service (next-best-action) | Data Cloud segment + NBA |
| scheduled sweep / record-triggered handoff Flow | journey entry + wait steps |
| consent-gated Apex `EmailService` send | the Marketing Cloud send (the piece you *delete*) |
| a CRM `*_Consent__c` flag | ContactPointConsent / effective consent + subscriber status |
Migration = keep Data Cloud as the brain and Agentforce as the reasoning/rep layer; **swap the Apex send for a journey enrollment / consent-aware activation.** Everything else stays.

Sources: Data Cloud Consent & Preferences data model; Data Cloud Activation (consent on activation); Marketing Cloud Connect; Marketing Cloud Growth (Data Cloud-triggered Flow sends).
