# Digital + Voice Service Channels (DX reference)

> Field/element names verified against a live Summer '26 org (`sf sobject describe`, `sf project retrieve`) + v67 PDFs. The org is the source of truth for sparsely-documented MIAW/Voice XML.

## Top correctness traps
| Trap | Right answer |
|---|---|
| MIAW vs legacy chat | MIAW = `EmbeddedMessaging` + **`BrandingSet`**; legacy = `WebChat` + `EmbeddedServiceBranding`. Build MIAW. |
| Channel kind | Object field = **`MessageType`**; metadata element = `<messagingChannelType>`. |
| "Switch to V2" | **Do NOT** if you need JWT login verification — **v2 drops user verification**. Stay on v1. |
| `setIdentityToken` timing | Call **inside `onEmbeddedMessagingReady`** or user → Guest even with a valid JWT. |
| Omni routing flow | `Flow` `<processType>` = **`RoutingFlow`**. |
| Identity stitching | Write `ContactId`/`AccountId`/`LeadId` on **`MessagingEndUser`** — session `EndUser*Id` are read-only mirrors. |
| Transcripts | `ConversationEntry`/`Conversation` are **off-platform** — never SOQL; use Conversation Data GET API / Data Cloud. |
| Open CTI | **Maintenance mode, EOL Feb 28 2028** — build net-new telephony on Salesforce Voice. |
| SCV rebrand | "Service Cloud Voice" → **Salesforce Voice** (API names unchanged). |

## PART A — MIAW / Enhanced Messaging

### A1. `MessagingChannel`
One inbound endpoint (web chat, SMS, WhatsApp, FB, Apple MfB). **EmbeddedMessaging channels ARE metadata-deployable.** (`messagingChannels/<Name>.messagingChannel-meta.xml`)
```xml
<MessagingChannel xmlns="http://soap.sforce.com/2006/04/metadata">
  <masterLabel>Kwitko Web Chat</masterLabel>
  <messagingChannelType>EmbeddedMessaging</messagingChannelType>
  <sessionHandlerType>Flow</sessionHandlerType>            <!-- Flow | Queue -->
  <sessionHandlerFlow>Kwitko_Web_Chat_Routing</sessionHandlerFlow>
  <sessionHandlerQueue>Kwitko_Chat_Fallback</sessionHandlerQueue>
  <customParameters>                                       <!-- hidden pre-chat / identity params -->
    <name>Logged_In_Email</name><masterLabel>Logged In Email</masterLabel>
    <externalParameterName>loggedInEmail</externalParameterName>
    <parameterDataType>String</parameterDataType><maxLength>255</maxLength>
  </customParameters>
</MessagingChannel>
```
- `MessageType` (SOQL field) full set: `Text, Facebook, Line, AppleBusinessChat, WeChat, WebChat, WhatsApp, Phone, EmbeddedMessaging, Voice, Custom, Email, Rcs, …`. Map: Web/In-App MIAW=`EmbeddedMessaging`, legacy=`WebChat`, SMS=`Text`, WhatsApp=`WhatsApp`, FB=`Facebook`, Apple=`AppleBusinessChat`, BYOC=`Custom`.
- Object routing fields: `RoutingType` (`OmniQueue`/`OmniSkills`), `RoutingConfigurationId`, `TargetQueueId`, `SessionHandlerId`, `FallbackQueueId`, `BusinessHoursId`, `IsRestrictedToBusinessHours`. Consent: `ConsentType` (`ImplicitOptIn`/`ExplicitOptIn`/`DoubleOptIn`). `PlatformType` (`Standard`/`Enhanced`) — set **Enhanced** for Agentforce-routable channels.
- **Gotchas:** `MessageType` ≠ `<messagingChannelType>`. SMS/WhatsApp/FB/Apple are provider- & OAuth-gated (metadata carries config of an *already-provisioned* channel); provisioning state is read-only in `MessagingChannelUsage.DeploymentStatus` (`New/Provisioning/Active/…`) — query for `Active`. WhatsApp number must activate within ~14 days. BYOC uses `ConversationChannelDefinition`+`ConversationVendorInfo` (use the event-driven fields; older fields removed v66).

### A2. Embedded Service web deployment — `EmbeddedServiceConfig`
Container tying MessagingChannel + pre-chat + branding + components; emits the install snippet. (`EmbeddedServiceConfig/<Name>.EmbeddedServiceConfig`, **no package.xml wildcard — enumerate members**)
- Top-level: `masterLabel`, `site` (req — ESW/Experience site), `deploymentFeature` (`EmbeddedMessaging`), `deploymentType` (`Web`), `branding` (**BrandingSet** dev name — `EmbeddedServiceBranding` is legacy-chat only), `areGuestUsersAllowed`, `authMethod`, `isEnabled`.
- MIAW subtype `embeddedServiceMessagingChannel` (v62+, all booleans required): `messagingChannel` (FK), `isEnabled`, `shouldShowTypingIndicators`, `shouldShowReadReceipts`, `shouldShowDeliveryReceipts`, `shouldShowEmojiSelection`, `shouldStartNewLineOnEnter`, `businessHours`.
- `EmbeddedServiceMenuSettings` (v47+, Channel Menu launcher): `embeddedServiceMenuItems` (`channelType`, `channel`, `displayOrder`, `iconUrl`).
- **Bootstrap snippet** (`init` takes 4 args):
```js
embeddedservice_bootstrap.init('ORG_ID','eswConfigDevName','https://<site>.my.site.com/ESW...',
  { scrt2URL: 'https://<myorg>.my.salesforce-scrt.com' });
```
`settings.*` (before init): `chatButtonPosition`, `hideChatButtonOnLoad`, `clearSessionOnChannelChange`. **Logout reset:** `embeddedservice_bootstrap.utilAPI.clearSession()` (fixes logout-session PII persistence). Events: `onEmbeddedMessagingReady`, `onEmbeddedMessagingIdentityTokenExpired`.
- **Genuinely UI-only:** publishing the deployment + generating the snippet (orgId/siteUrl/scrt2URL) — Setup → Embedded Service Deployments → Code Settings; deployment must be **Published**. On Experience Cloud sites the bootstrap goes in head markup.

### A3. Conversation lifecycle objects
```
MessagingChannel ─< MessagingEndUser ─< MessagingSession ── Conversation ─< ConversationParticipant (read-only)
Contact/Lead/Account ─┘ (identity)                                        └─ ConversationEntry (OFF-platform)
```
- **`MessagingSession`** — routed work unit. `Status` (system-managed: `New, Waiting, Active, Paused, Inactive, Consent, Ended, Error`), `Origin`, `MessagingEndUserId`, `MessagingChannelId`, `ConversationId`, `EndUserAccountId`/`EndUserContactId` (**read-only mirrors of MEU**), `CaseId`/`LeadId` (writable), `OwnerId` (Omni hook). **Extend** ("Support Context Passing") with `__c` fields populated from the Omni flow's Update Records.
- **`MessagingEndUser`** — identity lives here: `MessagingPlatformKey`, `MessageType`, **`ContactId`/`AccountId`/`LeadId` (writable — stitch to CRM; Person Account → `AccountId`)**, `MessagingConsentStatus`, **`AuthenticatedEndUserId`→User (read-only — set by JWT verification; the spoof-proof identity signal)**.
- **`ConversationParticipant`** — read-only (no DML); join via `MessagingSession.ConversationId`.
- **`ConversationEntry`** — OFF-PLATFORM actual messages, **not SOQL/report-accessible**. `EntryType`, `ActorType` (`System`/`Agent`/`EndUser`/`Bot`), `Message`. Access via Conversation Data GET API or Data Cloud sync.
- **`MessagingDeliveryError`** — outbound health; alert on `Type='Error'`.

### A4. Pre-chat, greetings, business hours, routing
- **Pre-chat:** standard fields `_firstName`/`_lastName`/`_email`/`_subject`. Bootstrap **Pre-Chat API** (inside `onEmbeddedMessagingReady`): `prechatAPI.setHiddenPrechatFields({var:value})`, `setVisiblePrechatFields(...)`. Metadata form = `EmbeddedServiceConfig.embeddedServiceForms` → `EmbeddedServiceForm` → `EmbeddedServiceFormField`. Field→record wiring: custom MessagingSession field → Omni flow input var → **Parameter Mappings** (Setup-UI) → hidden pre-chat field → Flow Update Records → agent var **`linked`**. **Hidden pre-chat is spoofable** (not JWT-verified).
- **Auto-greetings:** Messaging Components assigned per channel to Start/End/Inactive Conversation (Setup-UI binding). Channel object also has deployable text fields `InitialResponse`/`OutsideBusinessHoursResponse`/etc.
- **Business hours:** `BusinessHours` (deployable/`sf data`: `TimeZoneSidKey`, `{Day}StartTime`/`EndTime`) + `Holiday` (junction `BusinessHoursHoliday`, linking typically UI). Attach via `MessagingChannel.BusinessHoursId`.
- **Omni-Channel Flow** (`processType=RoutingFlow`): input `recordId` (the MessagingSession id) + Route Work (last on path) → Bot (active Agentforce)/Queue/Skill/User; always a fallback queue. See [omni-channel-routing.md](omni-channel-routing.md).

### A5. Enhanced channels (SMS/WhatsApp/FB/Apple)
"Enhanced" = persistent **async** conversations, session transfer, supervisor collaboration, messaging components, bot/Agentforce routing. Standard channels are synchronous/ephemeral. Native SMS/WhatsApp/Web don't need you to author `ConversationChannelDefinition`; **partner/BYOC** channels do (+ `ConversationVendorInfo`, v60+). Provisioning (WhatsApp/FB/Apple) is genuinely UI/OAuth-gated (interactive Meta OAuth). Grant the Messaging perm set + FLS on custom MessagingSession fields or routing silently drops data.

### A6. Messaging components & templates
Enhanced-channels only, built in the Messaging Component Builder. Message types → formats: `StaticContentMessage`(Text/RichLink/Attachments/WebView), `ChoicesMessage`(Buttons/QuickReplies/Carousel), `FormMessage`(Inputs). `MessagingTemplate` (Metadata API type + object, v47+) + `MessagingChannelMessagingTemplate` junction. WhatsApp template approval: notification component → Add Format → External Template → **Activate (submits to Meta, ~1 day)**; categories Utility/Marketing supported, **Authentication category NOT** (use in-session Authentication Request). Keep the `Text` default as fallback.

### A7. JWT user verification (CRITICAL)
Turns a guest conversation into a verified one. **JWT:** alg **RS256/RS512**, header `kid` (matches the uploaded JWK), payload `sub` (unique id → verified identity), `iss` (matches the keyset issuer), `exp`. JWKS: RSA-2048. **Config (Setup):** channel → User Verification Configuration → add the JWK Set; `Authorization Token Expiration Time for Verified Users` (default 60 min) is separate from your token `exp`.
```javascript
window.addEventListener("onEmbeddedMessagingReady", () => {
  embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({ identityTokenType:"JWT", identityToken:myJwt });
});
embeddedservice_bootstrap.init(/* deployment params */);
```
- Call `setIdentityToken` **inside `onEmbeddedMessagingReady`**, per tab, **again after every refresh** (token is in-memory only). `onEmbeddedMessagingIdentityTokenExpired` → ~30s to supply a fresh token. `clearSession()` on logout.
- **⚠️ v1 vs v2:** v1 supports custom components + CSS branding + `setIdentityToken`; **v2 removes user verification** (Setup-only theming, no custom components). **Stay on v1 if you need login/JWT verification.** Verification is all-or-nothing per deployment (channel-level JWT would block guests too) — hardening alternative = server-side email before `init()` + force-fresh on auth change + `clearSession()` on logout.
- **⚠️ Timing bug:** `setIdentityToken` *outside* the listener → fires before the API is ready → user treated as Guest despite a valid JWT.

### A8. Routing to Agentforce/Einstein Bot vs human
Enhanced channel → Omni-Channel Flow (`RoutingFlow`) → Route Work to bot (Agentforce — Route Work labels the target `Bot`)/queue/skill/human. **Agentforce** runtime = `GenAiPlannerBundle` (authored via Agent Script / `sf agent`); **Einstein Bot** = `Bot`+`BotVersion`+`MlDomain`. Bot→human handoff with context: custom MessagingSession field (e.g. `Inquiry_Category__c`) populated by an Update-Messaging-Session flow (map `RoutableID`=the session id), read by the outbound Omni flow Decision → Route Work + fallback; agent var **`linked`**. `sf agent publish` ≠ activate. FLS on the custom field required or context silently fails.

## Channel availability on a Developer Edition org (what you can actually enable)
- **Web / In-App (MIAW)** — ✅ available; `MessagingChannel` (`EmbeddedMessaging`) + `EmbeddedServiceConfig` are deployable; deployment publish + snippet is Setup-UI.
- **Web-to-Case** — ✅ available (org pref, often on by default).
- **Email-to-Case (On-Demand)** — ✅ enableable headlessly: set `CaseSettings.emailToCase.enableEmailToCase=true` + `enableOnDemandEmailToCase=true` (deploys cleanly; verified the flag flips). Remaining = create + **verify a routing address** (the emailed-link verification + the generated `…@email.salesforce.com` address are per-org **UI/runtime-only**), and real delivery still depends on the org's OWEA/DMARC.
- **SMS / WhatsApp / Facebook / Apple Messages for Business** — ❌ NOT on a plain Developer Edition: they need the **Digital Engagement** add-on license **and** provider provisioning (a long/short code, or interactive Meta OAuth + a WhatsApp Business number). The `MessagingChannel` *shell* can deploy but the channel can't be provisioned without the license + provider.
- **Voice (Service Cloud / Salesforce Voice)** — ❌ needs the SCV add-on + a telephony provider (Amazon Connect / partner); not on a plain dev org.
- Net: on a vanilla dev org the realistically-addable service channels beyond web chat are **Email-to-Case and Web-to-Case**; everything else is license-gated.

## PART B — Salesforce Voice / Telephony
- **Models:** SCV with **Amazon Connect** (Salesforce-managed, native AWS AI), **Partner Telephony / BYOT** (Genesys/NICE/Five9/etc. managed package + Telephony Integration REST API), **Partner Telephony from Amazon Connect / BYOA** (you own AWS — direct pricing, AWS AI). Add-on SKU on Service Cloud seats; **assign Voice/Conversation-Insights perms BEFORE go-live** — calls placed before are never processed (no recording/transcript).
- **`CallCenter`** metadata (`callCenters/<Name>.callCenter`) is the integration anchor for both Open CTI and Voice/partner connectors. `reqInternalName`, `reqSalesforceCompatibilityMode` (set `Lightning`/`Classic_and_Lightning`), and for Partner Telephony `reqVendorInfoApiName` → **`ConversationVendorInfo.DeveloperName`** (the critical wiring; both deployable). AWS role ARNs/certs/IdP/Connected App are guided-Setup-only.
- **`SoftphoneLayout`** (fields/screen-pop per call direction). **`VoiceCall`** (v40+): `CallType` (`InboundCall`/`OutboundCall`/`Transfer`/`Conference`), `CallDisposition`, lifecycle datetimes, `CallDurationInSeconds`, `ConversationId`, `VendorCallKey`, `CallCenterId`, `RelatedRecordId`, `PreviousCallId`/`NextCallId`/`ParentVoiceCallId`, `RecordingFilePath`. Create (BYOT) via Telephony Integration REST API `POST /telephony/v1/voiceCalls`. Related: `VoiceCallRecording`, transcripts = `ConversationEntry` (via Conversation REST), `VoiceVendorInfo`/`VoiceVendorLine`, `UnifiedVoiceCall` (Data Cloud).
- **Open CTI** (`lightning/openCTI`: `screenPop`, `searchAndScreenPop`, `runApex`, `onClickToDial`) — **EOL Feb 28 2028**; for net-new use Voice connectors + REST API.
- **Conversation Intelligence (ECI):** `ConversationalIntelligenceSettings` metadata (deploy/promote enablement) + assign "Conversation Insights for Service" PSL **before** go-live. **Summer '26: ECI is now platform-native** (standard objects → Flow/Apex/Prompt Builder accessible). Connecting a recording/meeting provider (OAuth) is Setup-UI-only; no backfill of pre-permission calls.

## Build-order cheat sheet (MIAW web chat → Agentforce)
1. Enable (Setup-UI): Messaging for In-App & Web, Omni-Channel, Service perms.
2. `BusinessHours` (+`Holiday`) → `ServiceChannel` → `RoutingConfiguration` → fallback `Queue`.
3. Flow (`RoutingFlow`) with `recordId` + Route Work → **active** Agentforce agent.
4. Custom `__c` fields on `MessagingSession` (Support Context Passing).
5. `MessagingChannel` (`EmbeddedMessaging`, `sessionHandlerType=Flow`, `customParameters`).
6. `BrandingSet` → `EmbeddedServiceConfig` (`embeddedServiceMessagingChannel`, `embeddedServiceForms`).
7. Setup-UI: publish deployment + copy snippet; Parameter Mappings; assign Messaging Components; JWT key set.
8. Bootstrap `init(orgId, eswConfigDevName, siteUrl, {scrt2URL})`; `setIdentityToken` (RS256) inside `onEmbeddedMessagingReady`; `clearSession()` on logout.

## Key doc URLs
[MessagingChannel](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_messagingchannel.htm) · [EmbeddedServiceConfig](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_embeddedserviceconfig.htm) · [Messaging Object Model](https://developer.salesforce.com/docs/service/messaging-object-model/guide/messaging-object-model.html) · [User Verification](https://developer.salesforce.com/docs/service/messaging-web/guide/user-verification.html) · [MessagingSession](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_messagingsession.htm) · [MessagingEndUser](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_messagingenduser.htm) · [CallCenter](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_callcenter.htm) · [VoiceCall](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_voicecall.htm) · [Telephony Integration REST API](https://developer.salesforce.com/docs/atlas.en-us.voice_developer_guide.meta/voice_developer_guide/voice_rest_overview.htm)
