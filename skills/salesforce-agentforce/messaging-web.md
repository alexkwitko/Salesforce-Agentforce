# Messaging for Web (MIAW) embedded chat

The customer-facing web chat = an **Embedded Service deployment (WebV2)** + a **MessagingChannel** routed via an **Omni-Channel flow** to an Agentforce **Service Agent**.

## Components & metadata
- **`EmbeddedServiceConfig`** — the deployment (served as `esClientVersion = WebV2`). The site is provisioned when the deployment is published.
- **`MessagingChannel`** (`messagingChannelType: EmbeddedMessaging`) — the channel. Carries custom parameters, keywords, and the routing handler.
- **Omni-Channel routing flow** (`processType RoutingFlow`) — required to reach a Service Agent.
- **`Queue` + `QueueRoutingConfig`** — fallback queue (needs an attached routing config or it won't appear in the Route Work picker).
- **`Site`** — the public site backing the deployment.

## Routing: you MUST use an Omni-Channel flow (not direct channel routing)

Direct channel routing with Routing Type = "Agentforce Service Agent" never creates a `PendingServiceRouting` → the `MessagingSession` is stuck `Status=Waiting`, 0 agent messages → the widget shows "Agents are not available." The working chain:
- Omni-Channel flow with a **Route Work** element: recordId var, Service Channel = Messaging (`sfdc_livemessage`), Route To = Agentforce Service Agent → your agent, fallback = a queue.
- The fallback `Queue` must have a `<queueRoutingConfig>` (routingModel MostAvailable, Units of Capacity 1) or it won't show in the Route Work fallback picker.
- The MessagingChannel points at the flow:
```xml
<MessagingChannel xmlns="http://soap.sforce.com/2006/04/metadata">
  <messagingChannelType>EmbeddedMessaging</messagingChannelType>
  <sessionHandlerType>Flow</sessionHandlerType>
  <sessionHandlerFlow>My_Web_Chat_Routing</sessionHandlerFlow>
  <sessionHandlerQueue>My_Chat_Fallback</sessionHandlerQueue>
  ...
</MessagingChannel>
```
Working result: new `MessagingSession = Active`; an SSE `CONVERSATION_MESSAGE` from `role=Chatbot`.

## Passing context to the agent (custom parameters + pre-chat)

Define custom parameters on the channel; each maps an external (browser-sent) parameter name to an `actionParameterName` that flows to the routing flow variable and then the agent variable:
```xml
<customParameters>
  <actionParameterMappings>
    <actionParameterName>loggedInEmail</actionParameterName>
  </actionParameterMappings>
  <externalParameterName>LoggedIn_Email__c</externalParameterName>
  <name>Logged_In_Email</name>
  <parameterDataType>String</parameterDataType>
  <maxLength>255</maxLength>
</customParameters>
```
The website sends these as **hidden pre-chat fields** keyed by the **`externalParameterName`** (e.g. `LoggedIn_Email__c`), inside `onEmbeddedMessagingReady`:
```js
embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
  LoggedIn_Email__c: me.email,
  LoggedIn_First_Name__c: me.firstName,
});
```
Gotchas:
- Use the **exact `externalParameterName`** as the key (e.g. `LoggedIn_Email__c`), not the friendly/variable name — wrong keys produce `validatePrechatField invalid field name` console spam and null values land on the session.
- Pre-chat fields apply only at the **start of a NEW conversation** — existing sessions predate any change, so always test in a fresh chat.
- Don't rely on a cached page footer for the email; fetch a dynamic, never-cached endpoint.

## JWT user verification (recognize the signed-in shopper)

Goal: a verified email lands on `MessagingEndUser`/`MessagingSession` so the agent recognizes the shopper. The pieces:
- Website serves a valid **RS256 JWT**: header `{alg:RS256, kid:"<kid>"}`, claims `sub, iss="<issuer>", iat, exp, email, ...`.
- Website exposes a **JWKS** endpoint deriving only the public key `{n,e}` (never expose the private key).
- Salesforce: Setup → Service → Embedded Service → **Enhanced Chat User Verification** → register a JSON Web **Key** (matching `kid`, Active) + JSON Web **Keyset** (matching `issuer`).
- Client applies the token INSIDE the ready handler, AFTER awaiting the fetch:
```js
window.addEventListener('onEmbeddedMessagingReady', async () => {
  const r = await fetch('/wp-json/.../jwt', {credentials:'include', headers:{'X-WP-Nonce': NONCE}});
  if (!r.ok) return;                       // stays guest if not logged in
  const {jwt} = await r.json();
  embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({ identityTokenType:'JWT', identityToken: jwt });
});
// also re-apply on 'onEmbeddedMessagingIdentityTokenExpired'
```

### Two critical gotchas
1. **Timing bug:** if `setIdentityToken` is called OUTSIDE `onEmbeddedMessagingReady` (or before the async JWT fetch resolves), the token is dropped → every session is Guest even though the JWT is perfectly valid. Apply it inside the ready handler. (Note: `settings.identityToken` reading `false` afterward is EXPECTED — the API consumes the token; it is not a failure signal. Confirm verification by checking `MessagingEndUser`/`MessagingSession` is non-Guest with Account/Contact populated.)
2. **`authMode=UnAuth` blocks everything (the real wall):** even with a valid JWT + matching Active keyset, `setIdentityToken` is **silently ignored** when the served config shows `embeddedServiceMessagingChannel.authMode = UnAuth`. Check it:
   ```bash
   curl -s "${SCRT}/embeddedservice/v1/embedded-service-config?orgId=${ORG}&esConfigName=${DEPLOYMENT}&language=en_US" \
     | jq '.embeddedServiceConfig.embeddedServiceMessagingChannel.authMode'
   ```
   In this org there was NO Setup UI, Metadata, or Tooling field to flip `authMode` / attach the keyset to the deployment — it required a **Salesforce Support** case ("enable user verification / set the deployment to accept the registered keyset"). `setIdentityToken` on an UnAuth deployment errors `Invalid user verification authentication mode: UnAuth`.

> Do NOT assume "Enhanced Chat v2 removes user verification" — modern **WebV2 exposes `userVerificationAPI`**. (An old "switch to v2 loses verification" dialog existed for an earlier v2; it does not describe current WebV2.) The blocker is `authMode`, not the client version.

## Identity lifecycle: login/logout WITHIN a live conversation (the leak + the over-block)
Hidden-prechat identity is bound at **conversation creation** and never re-checked per turn. That causes two symmetric bugs:
- **Logout leak:** a conversation started while signed-in keeps disclosing PII after the user logs out (the MIAW conversation persists in the browser; the agent re-uses the creation-time identity).
- **Over-block / mid-chat login:** a conversation started as a guest stays guest even after the user signs in — `setHiddenPrechatFields` after creation does not update the existing conversation.

**Fix (client bridge): end the conversation on ANY identity change so a fresh one is created with the right routing attributes.**
- Keep an identity fingerprint in `localStorage` (`"user:<email>"` or `"guest"`). On `onEmbeddedMessagingReady`, compare it to the current server-truth identity; if it changed, call **`embeddedservice_bootstrap.utilAPI.clearSession({ shouldEndSession: true })`** (the `shouldEndSession:true` is what actually ends an authenticated conversation — bare `clearSession()` is a no-op) BEFORE setting hidden prechat fields. Then store the new fingerprint.
- Use `clearSession({shouldEndSession:true})` **only** for the identity-refresh (it keeps the launcher button). Reserve `removeAllComponents()` for true logout/teardown — calling it after `init()` removes the launcher and it won't return without a re-init.
- Add a periodic `/me`-style auth re-check (e.g. every 30s) to catch a same-tab logout; on the logged-in→guest transition, end the session.
- Render the signed-in identity **server-side** into the page (synchronous) so the prechat field is available before the conversation starts — don't depend only on an async fetch (race).

**The real fix for the leak is token expiry, not client cleanup:** with JWT User Verification the verified identity represents "currently logged in" and a short token TTL de-verifies the session on logout automatically. Client cleanup is best-effort; JWT is the durable fix.

## Verified vs guest is ALL-OR-NOTHING per deployment
A deployment configured for User Verification expects verified users; you **cannot** cleanly serve both verified and anonymous guests from the **same** embedded deployment. For a site that must serve guests (most storefronts/portals) AND recognize signed-in users cryptographically, use **two deployments** — a guest (UnAuth) one and a verified one — and have the page bootstrap whichever matches the current login state. Don't flip the single live deployment to verified-only; it locks out guests. (Until you do this, the backend agent/Apex consent gate is what actually prevents impersonation — channel JWT is defense-in-depth, not the only guard.)

## Page-cache / stale-nonce trap (signed-in user looks like a guest)
If the page that hosts the chat is served from a CDN/page cache, the bridge can receive a **stale auth state and a stale REST nonce** — so a genuinely-signed-in user is seen as a guest (over-block), or a logged-out tab shows stale signed-in content. Before blaming the JWT/prechat wiring, confirm the auth endpoint returns the *correct* state for the *current* session (a stale nonce makes authenticated REST calls read as logged-out even with the cookie present). Fix: **exclude logged-in users / the chat-bearing pages from page cache** so the bridge always gets a fresh nonce + identity.

## Live conversation test via the SCRT API (no widget needed)

The embedded launcher is a cross-origin shadow-DOM iframe — synthetic clicks/typing don't reliably reach it. Drive the conversation over REST/SSE instead.

Unauthenticated path (used by the smoke test):
```bash
SCRT=https://<myorg>.develop.my.salesforce-scrt.com
ORG=00Dxxxxxxxxxxxx
DEP=My_Web_Chat_V2
# 1) get an unauth access token
TOKEN=$(curl -fsSL -X POST -H 'Content-Type: application/json' \
  --data '{"orgId":"'"$ORG"'","developerName":"'"$DEP"'","capabilitiesVersion":"260"}' \
  "$SCRT/iamessage/v1/authorization/unauthenticated/accessToken" | jq -r .accessToken)
# 2) create a conversation
curl -sS -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  --data '{"language":"en_US","conversationModes":["Messaging"]}' \
  "$SCRT/iamessage/v1/conversation"
```
- A **412 "Conversation Precondition failed"** here is, in a Developer Edition org, almost always **storage exhaustion** (no records can be created), not a config error — check `troubleshooting.md` FIRST.
- For an authenticated/verified test, use the JWT instead of the unauth token, then open SSE at `/eventrouter/v1/sse` (headers `Authorization`, `X-Org-Id`, `Accept: text/event-stream`) and read `CONVERSATION_ROUTING_RESULT` / `CONVERSATION_MESSAGE` events.

## Where the transcript lives
Native `MessagingSession`/`ConversationEntry` may not be persisted — keep an agent-written summary on durable records: a Lead summary field, a Contact Task, and the `Case.Description` (32k long-text, under a "--- Chat transcript ---" header) + a Case Task. Make the agent's `open_case` action take a **required** `chatSummary` input and instruct it to always attach the transcript.

## Passing hidden pre-chat identity to an Agentforce Service Agent (the full chain that actually works)

A channel `customParameter` does NOT auto-reach the agent. Three pieces must all be in place:

1. **Channel customParameter** — `externalParameterName` = the client-sent key (also the MessagingSession field API name), `actionParameterName` = the RoutingFlow input-variable name.
2. **RoutingFlow writes the MessagingSession field.** The Omni RoutingFlow receives the customParameter as a flow **input variable named after the `actionParameterName`**. The flow must then **Update Records** on the MessagingSession (`Id = {!recordId}`) to set the custom field from that input var. Without this, the field stays null and nothing downstream sees the value. (A guard decision around the update is optional but tidy.)
3. **Agent variable must be `linked`, not `mutable`.** In Agent Script, declare:
   ```agentscript
   loggedInEmail: linked string
       source: @MessagingSession.Kwitko_Logged_In_Email__c
   ```
   A `mutable` variable becomes a BotVersion **conversationVariable** that is ALWAYS EMPTY on the live channel (it's only settable via the Agent API `context_variables` injection — which is exactly why run-eval "verified" cases pass while the LIVE chat fails). The MIAW value lands in the Bot **contextVariable** of the same name; a `mutable` declaration shadows it. `linked` (read-only, `source:`, no default) is referenced with the SAME `{!@variables.X}` syntax, so no instruction edits are needed. Then validate → publish → **activate**.

**Exact `setHiddenPrechatFields` key = the served config's `hiddenFormFields[].name`**, fetched from `…my.salesforce-scrt.com/embeddedservice/v1/embedded-service-config?orgId=…&esConfigName=…`. WebV2's bootstrap validator **rejects the entire call** if any key isn't a configured hidden field — never hedge alias keys.

**Storage-free live-agent test (skip the 5MB AI-Evaluation catch-22):** drive the real Service Agent over SCRT2 REST+SSE instead of `sf agent test`:
- token: `POST /iamessage/v1/authorization/unauthenticated/accessToken` `{orgId, developerName, capabilitiesVersion:"260"}`
- SSE: `GET /eventrouter/v1/sse` headers `Authorization: Bearer <tok>`, `X-Org-Id`, `Accept: text/event-stream`
- create: `POST /iamessage/v1/conversation` `{conversationId:<uuid>, routingAttributes:{<hiddenFieldName>:value}}` (object only; NO `esDeveloperName`)
- send: `POST /iamessage/v1/conversation/<id>/message` `{id:<uuid>, messageType:"StaticContentMessage", staticContent:{formatType:"Text", text:"…"}}` (top-level; NO `esDeveloperName`)
- read `CONVERSATION_MESSAGE` events. Creates a real MessagingSession but **zero** AI-Evaluation records.

**Security:** hidden-prechat identity is **trust-on-assertion** — anyone hitting the SCRT API can put any email in `routingAttributes`. Render it server-side for UI users, but for real trust use **User Verification (JWT)**: attach a keyset to the deployment and flip `authMode` UnAuth→Auth (UI-gated). Until then, `setIdentityToken` is silently ignored on an UnAuth deployment.

## Client-side embed & identity bridge (host-page patterns)
How to wire reliable identity into the chat from ANY host site. Keep the official Salesforce embed loader untouched; put all identity/reset/stitch logic in a **companion bridge script** that only attaches to `window` + the `onEmbeddedMessagingReady` event (never calls `bootstrapEmbeddedService` itself). Guard every call (`if (window.embeddedservice_bootstrap && embeddedservice_bootstrap.prechatAPI && typeof …setHiddenPrechatFields==='function')`) so it's load-order-agnostic.

- **One namespaced config object, server-rendered:** print current login state + a feature flag synchronously into a single global (`window.APP_CHAT = Object.assign({}, window.APP_CHAT||{}, {meUrl, jwtUrl, nonce, loggedIn, email, firstName, jwtUserVerification})`). Additive snippets/hotfixes read & extend it; idempotency guards (`if (window.X_VERSION===V) return;`) let them coexist. Server-rendering identity is what avoids the async race.
- **Dual-mode toggle:** a `jwtUserVerification` boolean lets the SAME bridge run hidden-prechat-only on an UnAuth deployment and switch on `setIdentityToken` once the verified deployment's `authMode` is flipped — no code change, just the server flag. JWT paths early-return when it's false.
- **JWT is OPTIONAL when a backend gate exists (key cost saver):** if the Service Agent's actions are gated by Apex `IdentityService.isVerified(requestedEmail, verifiedEmail)` where `verifiedEmail` is the `linked` hidden-prechat email, then **passing one hidden field is functionally sufficient to "recognize" the user** — JWT/`setIdentityToken`/`authMode=Auth` (which needs a Support flip) become defense-in-depth, not a prerequisite. Add JWT later purely for cryptographic trust.
- **Discover the allowed hidden-field key from the served config — don't hard-code:** fetch `…/embeddedservice/v1/embedded-service-config?orgId=&esConfigName=&language=`, walk `embeddedServiceConfig.forms` for each node's `name/formField/fieldName/developerName/externalParameterName`, and send only the exact keys it expects (the WebV2 validator rejects the WHOLE `setHiddenPrechatFields` call if any key is wrong). Note the **two-name split**: EmbeddedServiceConfig `formField` uses the short channel-param `name`, but the browser must send the long `externalParameterName` (= the MessagingSession field API name) as the key.
- **Re-apply on a retry schedule, not once:** `[0,150,500,1500,3000,6000].forEach(d=>setTimeout(applyIdentity,d))` + `setInterval(applyIdentity, 15000–30000)`. `prechatAPI`/`userVerificationAPI` may not be attached at the exact ready event, and same-tab login/logout must be caught without a reload.
- **Reset depth ladder** (call all that exist — APIs vary by client version): `utilAPI.clearSession({shouldEndSession:true})` → bare `clearSession` → (logout teardown only) `removeAllComponents()` → `userVerificationAPI.clearSession(...)`. When residue remains, **nuke web storage**: iterate `localStorage`/`sessionStorage` and delete `key === orgId + '_WEB_STORAGE'` (where WebV2 persists the conversation handle) + anything matching `/embedded(service|messaging)|salesforce|scrt|ESW/i`, then re-init. Use a `sessionStorage` one-shot key to force a stale guest conversation to end exactly once per tab after sign-in (not every ready).
- **Cross-iframe login handoff:** the widget is a cross-origin shadow-DOM iframe you can't script. Open a modal with the **same-origin** login page in an iframe, detect success via its `load` event (`contentDocument` post-login markers) AND a `/me` poll, then **reload the parent** so the server issues a fresh authenticated nonce (a stale nonce makes `/me`/`/jwt` read logged-out even with the cookie). Trigger the modal from an agent-rendered in-chat link or `postMessage` gated on `e.origin===location.origin`.
- **Token-keyed server queue = bridge a server-side agent decision back to the chatting tab:** browser mints a durable `localStorage` token, passes it as a hidden prechat field, and polls `GET /identify?token=`; the agent (Apex) POSTs the verified email (HMAC-signed) keyed by that token; the browser on a hit calls your `identify()` then `DELETE`s the entry. Same pattern powers a "zero-click" action queue. Short-TTL, HMAC-signed, token-keyed — reusable for any deferred client action driven by the agent.

## Data Cloud Web SDK + behavioral capture (host-page)
- SDK global is **`SalesforceInteractions`** (connector CDN). Poll-wait for it (`retry every 100ms`) before `init({cookieDomain, consents:[{provider,purpose:'Tracking',status:'Opt In'}]})` + `initSitemap`.
- **Anonymous-first, `reset()` on identity change:** keep an identity fingerprint in `localStorage`; on change (or a cross-snippet `localStorage` reset flag set by the chat bridge) call `SalesforceInteractions.reset()` before re-identifying so the anonymous→person stitch is clean.
- **Identify = three `sendEvent`s:** `contactPointEmail` (email), `identity` (name + `isAnonymous:"0"`), `partyIdentification` (external id). Engagement via declarative listeners: `listener('change', "input[type=email]", …)` to identify pre-purchase, `listener('click', <cart selector>, …)` → `sendEvent({interaction:{name: CartInteractionName.AddToCart, lineItem}})`; PDP/category pages emit `CatalogObjectInteractionName.ViewCatalogObjectDetail`/`ViewCatalogObject`.
- Expose a small cross-snippet contract on `window` (`appIdentify(email,first,last)`, `appDataCloudReset()`) and de-dupe per page load (`window.__identifyDone===email`), so the chat bridge can stitch without knowing SDK internals.
- **Non-SDK fallback:** a behavioral beacon to a public Apex REST Site endpoint (`/services/apexrest/engagement`) — year-long `deviceId` cookie + `sessionStorage` sessionId, batched `{events,identify}` POSTs, with **dwell-time + max-scroll% flushed on `visibilitychange→hidden` and `pagehide`** (the reliable on-exit signal). CORS-allowlist the origin.
