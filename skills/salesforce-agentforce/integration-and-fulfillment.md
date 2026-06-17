# Integration, two-way sync, status source-of-truth & security config

How an Agentforce solution talks to an external system of record (commerce/ERP/billing/PIM/claims), keeps state consistent, and stays least-privilege. Product-agnostic — "external system" = whatever owns the transactional data.

## Inbound: HMAC-verified webhook ingestion via your own Apex REST
Expose `@RestResource` Apex through a public Site so the external system can push events.
- `@RestResource(urlMapping='/ext/order/*')` + `global without sharing` (guest can't see records, but Apex DML is system-mode → upsert without granting object CRUD).
- **Verify the signature over the RAW body BEFORE parsing:**
  ```apex
  String calc = EncodingUtil.base64Encode(
      Crypto.generateMac('hmacSHA256', RestContext.request.requestBody, Blob.valueOf(secret)));
  if (calc != sig) { res.statusCode = 401; return; }   // header: X-*-Signature
  ```
  Gotchas: MAC must be over `request.requestBody` (Blob), **not** a re-serialized map (re-serialization changes bytes → mismatch); look up the header **case-insensitively** (loop `request.headers.keySet()` with `equalsIgnoreCase`); accept a **fallback header name** so one endpoint serves both the platform's native webhook and a custom caller.
- **Handle the non-JSON "ping"**: platforms send a plaintext verification ping on webhook creation — after the signature check, `if (!raw.trim().startsWith('{')) return 200;`.
- Same pattern verifies any Shopify/Stripe/GitHub/etc. webhook — only header name + secret source change.

## Outbound: Named Credential callouts (no creds in code)
- Split **`NamedCredential` (SecuredEndpoint, holds only the Url)** + a separate **`ExternalCredential`** (holds auth). Set `allowMergeFieldsInBody/Header=false` (don't let merge fields leak into requests).
- Call with `req.setEndpoint('callout:<NamedCred>/path')` — no URL, no secret in source.
- **⚠️ The permission set must grant the External Credential PRINCIPAL** or the callout fails at runtime even though the Named Credential deployed fine (this is the outbound analog of the FLS gotcha):
  ```xml
  <externalCredentialPrincipalAccesses>
    <externalCredentialPrincipal><ExtCred>-<PrincipalName></externalCredentialPrincipal>
    <enabled>true</enabled>
  </externalCredentialPrincipalAccesses>
  ```
- When calling the external system's **custom** routes, sign the outbound body with the same HMAC (`Crypto.generateMac` + `X-*-Signature` header) so the far end can verify Salesforce is the caller. Two-directional HMAC, one shared secret.

## Secrets out of source
- **Protected Custom Metadata** (`<Secret>__mdt`, `visibility=Protected`, `Value__c` `SubscriberControlled`) read via a tiny accessor with a `@TestVisible Map overrides` so tests inject secrets — preferred for signing keys.
- **Hierarchy Custom Setting** (`<Settings>__c.Secret__c` via `getOrgDefaults()`) for an org/profile-overridable inbound secret. (Readable by any context with the object perm — use Protected CMDT for signing keys.)

## ⭐ Idempotent two-way sync WITHOUT loops or drift
The classic bug is "external-side change never flows back" (pure skip-if-exists) or "two writers fight" (blind overwrite). The correct shape:
- **Upsert by external id**, never insert: every synced record carries `<Ext>_Id__c` (Text, `externalId=true`).
- **Existing record → RECONCILE (selective field update), don't skip.** Skip-if-exists is what breaks back-sync.
- **Per-field ownership + only-promote-toward-terminal:** when a *local* workflow owns a state the remote doesn't know about, the inbound reconcile **refuses to downgrade** that field unless the remote status is terminal. ("preserve local state" guard.)
- **Filter the remote lifecycle to states that should exist as records:** keep a `NON_RECORD_STATUSES` set (drafts/abandoned/failed) skipped on CREATE so phantom records aren't born; a later real-status event creates it.
- **Consent monotonicity:** `if (consent) set true; else if (brand-new) set false;` — **never auto-revoke an existing opt-in** on resync (repeat everywhere consent is touched).

## ⭐ Single-writer status / source-of-truth ladder
When status comes from multiple sources (your field, the OMS, a carrier event), compute ONE effective status; never let agents read raw fields:
- **Numeric `rank()` ladder** with `shouldPromote(current, candidate)` that only moves status *up* — **status never regresses** except to a terminal state.
- **Terminal set** (Cancelled/Refunded/Returned/…) short-circuits all promotion.
- **Evidence-gated truth:** don't trust an upstream coarse status as proof of a downstream physical event — e.g. downshift remote "completed" to `Shipped` unless a delivery event proves `Delivered`.
- **Feature-tolerant SOQL:** wrap OMS-object queries (`Shipment`/`FulfillmentOrder`) in try/catch + `Schema.getGlobalDescribe()` field-existence checks so the same class runs in orgs lacking those features (a fallback field still works).
- Expose `canCancel()/canReturn()/hasTracking()` derived from the single computed status, so every agent action's eligibility answer is consistent and lives in one place. (Use a custom `*_Status__c` as the source of truth when the standard `Status` can lag.)

## Capture-now / sweep-later: synthesize an event the external system can't emit
For lifecycle events the source doesn't push (e.g. "abandoned" after inactivity):
1. A storefront/app snippet POSTs live state to your Apex REST (stored `Active`).
2. A **`Schedulable` sweep** (run by a privileged user; N offset `System.schedule` crons to fake every-15-min since cron has no comma-minutes) flips `Active→<Event>` after the inactivity window, then **reconciles against the authoritative outcome** (look for a real downstream record in `LAST_N_DAYS:n`) to mark `Converted` vs the event.
3. The state transition fires a **record-triggered Flow** → invocable → agent/action.
Generalizable: **poll-to-capture + scheduled state-transition + declarative trigger.**

## Transactional / destructive action conventions (any domain)
- **Callouts BEFORE DML, always** (Apex forbids callouts after uncommitted DML) — do external calls first, then write records.
- **Three-part guard on every destructive `@InvocableMethod`:** (1) identity gate (fail-closed), (2) eligibility from the truth service, (3) explicit `confirmed=true`. Otherwise return "please confirm" and do nothing.
- **Bounded autonomy in code** (dollar/quantity ceilings), not the prompt.
- **Idempotency returns success** ("already cancelled / already on file"), never an error, so agent retries are safe.
- **Always write a traceability trail:** actor + on-behalf-of (`'Chat Agent (' + UserInfo.getName() + ') on behalf of ' + email`), a status note, and a Case — **Closed when resolved, or New + High priority when the external call FAILED** (so a human follows up instead of a silent failure) — plus a transcript Task and a cross-agent journey log.
- **Fail-closed external-dependency check:** when correctness depends on a deployed external component, call its `/health`-style endpoint and **refuse to proceed unless its reported version ≥ a known-good** (semver compare) — don't assume the remote side effect will happen.

## Omni-Channel routing for a Service Agent (the field-write half)
(Builds on `messaging-web.md`'s "use an Omni flow, not direct routing.") The RoutingFlow must, **before Route Work**, run a `recordUpdates` element that writes the channel customParameters (`loggedInEmail`, etc.) onto the **`MessagingSession`** (`Id={!recordId}`) so the agent can read them from a `linked` var. The fallback `Queue` needs a `QueueRoutingConfig` (`routingModel=MOST_AVAILABLE`, `capacityType=INHERITED`, `pushTimeout=20`) and `queueSobject=MessagingSession` or it won't appear in the Route Work picker.

## Security & org config — least privilege (DX metadata)
- **Webhook guest profile = Apex class access ONLY.** Zero object/FLS/CRUD (Apex DML is system-mode). Any object permission on a guest profile is a smell.
- **Service-agent runtime user permset:** `MessagingSession` Read+**Edit** (flow writes identity) but no Create/Delete; `MessagingEndUser` Read; `Case`/`Task`/etc. Create+Edit but **Delete=false, ViewAll/ModifyAll=false**.
- **`CorsWhitelistOrigin`** — the storefront/app origin must be allowlisted for browser→Apex-REST calls to succeed cross-origin.
- **`CspTrustedSite`** (`context=All`, `isApplicableToConnectSrc=true`, other src types false) — **required so the agent can surface an external URL without redaction** (Agentforce redacts links to non-trusted domains in its responses).
- **`CustomSite` hardening:** `browserXssProtection`, `clickjackProtectionLevel=SameOriginOnly`, `contentSniffingProtection`, `referrerPolicyOriginWhenCrossOrigin` on; turn off `allowHomePage/StandardSearch/StandardLookups` for a webhook/chat-only site; list the storefront in `siteIframeWhiteListUrls` for the embedded chat iframe.

## More lifecycle/action patterns (hard-won)
- **Separate the commitment record from the money-movement event.** Create the return/RMA/warranty record + label + customer note now with `refundIssued=false`; fire the actual refund callout only when the physical precondition is met (goods received). The agent truthfully says "refund processed after we receive the items" — never imply money moved early.
- **Refund/total amount source:** a whole-transaction refund uses the **external grand total** (incl. shipping/tax — the amount the customer actually paid), a partial uses summed line amounts — never the internal product-only subtotal. Same rule for any customer-facing total the agent quotes.
- **Match NL selection to line items:** map "just the dark one"/"all" to specific child line items; if nothing matches, return the item list and ask which (don't guess).
- **Flag-to-trigger-a-flow handoff:** an action sets a boolean/date flag (`Winback_Needed__c=true`, `*_Last_*_Date__c`) whose only purpose is to fire a separate record-triggered Flow — keeps the action focused and the follow-up declarative/restartable.
- **Two queue TYPES in one chat solution:** a `MessagingSession` queue *with* a `QueueRoutingConfig` (Omni Route Work) AND a separate `Case` queue *without* one used purely as the escalation `OwnerId` (look up by `Group WHERE DeveloperName=… AND Type='Queue'`). Different `queueSobject`, different layer — don't conflate.
- **Outbound catalog/PIM push (SF as system-of-record):** invocable → `System.enqueueJob(Queueable, AllowsCallouts)` so the callout leaves the trigger/flow transaction; **send the image `src` only on CREATE, never on update** (re-sending forces the remote to re-download → timeouts on slow hosts); `req.setTimeout(120000)`; stamp `*_Sync_Status__c`/`*_Last_Sync_Date__c`/`*_Sync_Error__c (.abbreviate(255))` for every outcome so sync state is queryable.
- **Deterministic idempotent code generation (issue-once tokens):** `code = PREFIX + Math.mod(Math.abs((key+amount).hashCode()), 100000)` → same inputs reproduce the same code (idempotent on retry), still guarded by a `count()==0` check before insert.
