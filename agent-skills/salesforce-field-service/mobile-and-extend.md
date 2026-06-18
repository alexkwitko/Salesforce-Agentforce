# Field Service — Mobile App & Extend Products

What's part of base FSL vs separately licensed. The mobile app, offline priming, Briefcase, push, and core shift objects are **part of FSL**. **Appointment Assistant, Visual Remote Assistant, Workforce Engagement, Salesforce Scheduler, and Agentforce** are **separate licenses**.

## 1. Field Service MOBILE APP (iOS/Android)
Native app "Salesforce Field Service" — **offline-first**; the field-facing client (console + scheduling stay on desktop).

**Two licensing layers (the #1 gotcha):**
- **Field Service Mobile** PSL → log into the app.
- **Field Service Scheduling** PSL → be scheduled / appear on the Gantt.
- A mobile worker (a `ServiceResource` type Technician) typically needs **both**.

**Standard perm set:** **`FieldServiceMobileStandardPermSet`** ("Field Service Mobile — Standard Permissions") — assign for the object/field access the app needs. Help: `service.mfs_perms_standard.htm`.

**Setup:**
1. Enable Field Service + install the managed package (adds geolocation, push, mobile app-settings).
2. Configure the **Field Service connected app** — required for push + Briefcase/offline transport.
3. Assign yourself **Field Service Admin Permissions**.
4. Guided Setup → **Create Service Resources**: pick the user, assign a territory, assign **both Scheduling + Mobile** licenses.
5. **Share the worker their own `ServiceResource` record (Read Only)** so the app can resolve "me".
6. Assign `FieldServiceMobileStandardPermSet` (+ resource perm sets).
7. **Field Service Mobile Settings** (Setup): branding, the **date-picker range** (Future/Past Days, default ~45 — drop to ~7/7 to speed priming), quick actions, required fields.
8. Push: Field Service Settings → Notifications → **Enable notifications** (`service.mfs_push_notifications.htm`).

**Offline — two mechanisms (don't confuse):**
- **Offline Priming** (built into the app) — auto pre-downloads the worker's assigned appointments + related records within the date window; supports queued offline actions. Tuned by the date range in Field Service Mobile Settings (`service.mfs_offline_parent.htm`).
- **Briefcase Builder** (Setup → **Offline → Briefcase Builder**; the setup node is `Briefcase`) — declaratively pushes *extra* records offline beyond priming: objects + filter criteria (≤10 filters, **indexed fields**, Order By SystemModstamp, ≥1 filter/object) assigned to users/groups. Needs the connected app. **The wizard (the canonical creation path — see the metadata phantom-deploy gotcha below) is 4 steps:** (1) Name + Developer Name; (2) **+ Add Object** → pick the object → set a rule `Filter By` field + `Criteria` (e.g. Equals) + `Value` (e.g. `Active`/`true`), set Filter by Owner; (3) **Assign** to Users/Groups/Profiles; (4) **Add Apps** (optional) → **Activate**. Limits shown live: up to **5 active** standard briefcases / **50,000** records. (Verified: a "Field Parts Catalog" briefcase = active `Product2` @ 500 records → 3 techs.)

Mobile workers update SA status (Dispatched → Traveling → On Site → Completed), capture notes/photos/signatures, add Products Consumed, run flows — offline-capable. Geolocation feeds the dispatcher + Appointment Assistant. Trailhead: `field-service-mobile`, `offline-briefcase`.

## 2. APPOINTMENT ASSISTANT — separate managed package (`FSA` namespace)
Customer-experience add-on; flagship feature **Real-Time Location**. Separately licensed.
- **Real-Time Location notifications** when the worker is en route (email / **SMS** / **WhatsApp**).
- **Live tracking + ETA on a map** (customer clicks a link, watches the worker approach).
- **"Arriving soon" / within-a-mile alert**.
- **Customer self-service** — accept a proposed schedule, adjust the time, or cancel.

**Setup:** (1) install from the same hub (`fsl.secure.force.com/install` → Appointment Assistant; or the d36…/install launcher) — incognito, Install for Admins Only, **approve third-party geolocation/optimization access**; (2) create a permission set, set its **License = Field Service Appointment Assistant**, enable the **Field Service Appointment Assistant** system permission; (3) assign to users; (4) configure the **Customer Journey** (channels + accept/adjust/cancel flow + tracking page). **Won't work with Trailhead Playground sample data** — needs a real org. Trailhead: `real-time-location-appointment-assistant`; install help `service.mfs_appointment_assistant_install_packages.htm`.

## 3. Visual Remote Assistant (separate license)
Live video / see-what-the-customer-sees with on-screen annotation — deflect truck rolls / assist field techs remotely. Requires Service Cloud or Field Service **+ a Visual Remote Assistant license**; Lightning Experience; install the managed package + configure perm sets. Help: `service.fs_intro_visual_assistance.htm`.

## 4. Workforce Engagement / shift scheduling (separate license)
Service Cloud Workforce Engagement (WFE) — forecast demand → recommend coverage → create/assign **shifts**. Shares the shift engine FSL uses but is a **separate add-on license**. Data model: `Shift`, `ShiftSegment`, `ShiftPattern`, `ShiftTemplate`, tied to `ServiceResource`. **Don't conflate** Field Service shifts ≠ WFE ≠ Salesforce Scheduler (three separate scheduling products). Help: `service.workforce_engagement_about_shift_scheduling_tools.htm`, `sf.fs_shifts_view.htm`.

## 5. Agentforce for Field Service (AI layer)
Built into the FS mobile app: **Pre-Work Brief** (audio work-order summary), **Knowledge Search** (NL search across Knowledge + bulletins + prior WOs → AI troubleshooting steps), **Post-Work Summary** (drafts the report, can schedule follow-ups), Siri-shortcut/voice access, and AI dispatch/scheduling. Rides on the Agentforce platform (separate consumption license). See the **salesforce-agentforce** skill.

## 6. Embed CUSTOM LWC in the mobile app (YES — offline-capable)
The SFS mobile app renders **Lightning Web Components as Lightning quick actions** (Spring '23+). This is the way to add custom one-tap workflows (e.g., a "Visit Assistant" that quotes / collects payment / generates the service report in one screen).
- **Mechanism:** LWC exposed with target **`lightning__RecordAction`**, registered as a **New Action → Lightning Web Component** on WorkOrder / ServiceAppointment / WorkOrderLineItem, then **added to that object's page layout** → appears in the mobile **Action menu**. `actionType="ScreenAction"` = modal UI; `actionType="Action"` = headless (runs `invoke()`, no UI). Component gets `@api recordId`.
  ```xml
  <targets><target>lightning__RecordAction</target></targets>
  <targetConfigs><targetConfig targets="lightning__RecordAction" actionType="ScreenAction">
    <objects><object>WorkOrder</object><object>ServiceAppointment</object></objects>
  </targetConfig></targetConfigs>
  ```
- **⚠️ Enablement gate:** the system permission **"Enable the Lightning SDK for online and offline use in the Field Service mobile app"** must be in the tech's permission set — **without it the LWC action never appears** in the app.
- **⚠️ Offline rules (Komaci static analyzer — confirmed via the Salesforce MCP `get_mobile_lwc_offline_guidance`):** (a) data access via **LDS / `lightning/uiGraphQLApi` (v1)** — NOT `lightning/graphql` (v2, no offline) and **NOT imperative Apex** (imperative Apex doesn't run offline; offline writes queue as **LDS drafts**); (b) **extract the GraphQL query into a getter**, never inline it in the `@wire` config; (c) use legacy **`if:true`/`if:false`, NOT `lwc:if`/`lwc:elseif`/`lwc:else`**; (d) keep GraphQL payloads **<~32 KB**. Lint with `@salesforce/eslint-plugin-lwc-mobile`; **run the Salesforce MCP `get_mobile_lwc_offline_guidance` + `get_mobile_lwc_offline_analysis` on every mobile LWC.** Violations silently break offline priming ("works in browser, blank in the van").
- **Device capabilities — `lightning/mobileCapabilities`** (mobile-app-only; always `isAvailable()` feature-detect): `getBarcodeScanner` (asset serials), `getDocumentScanner`, `getBiometricsService`, `getLocationService`, `getNfcService` (asset tags), `getAppReviewService`, geofencing, calendar, contacts, payments, AR space capture. The **Salesforce MCP scaffolds each**: `create_mobile_lwc_barcode_scanner` / `_document_scanner` / `_biometrics` / `_nfc` / `_location` / `_geofencing` / `_payments` / `_app_review` / `_calendar` / `_contacts` / `_ar_space_capture`.
- **Pick the surface:** **LWC quick action** = offline + custom UI (default). **App Extension** = punch out to an external URL/app, return to context (online; e.g., a card-reader app). **Deep Linking** (`fsl://`, ≤1 MB payload) = route *into* a screen/record/action from outside (push, QR). **Flow screen action** = declarative, but limited offline.
- **Test on a real device** — `mobileCapabilities` and offline priming don't run in desktop Lightning.
- **⚠️ Verified deploy gotchas (current orgs):** (a) the LWC `targetConfig` **rejects the `actionType` attribute** ("`'targetConfig' tag doesn't support the 'actionType' attribute`") — **omit it** (ScreenAction is the default), or just declare a bare `lightning__RecordAction` target with no targetConfig. (b) Register it as a **`QuickAction`** with `<type>LightningWebComponent</type>` + `<lightningWebComponent>cMyCmp</lightningWebComponent>` on the object. (c) **Don't metadata-override a layout that has no `<platformActionList>`** — you'll strip its default mobile actions; add the action in the **layout editor's "Salesforce Mobile and Lightning Experience Actions"** section instead (managed layouts like `FSL Work Order Layout` also hit the `Object-NS__Label` retrieve gotcha).

## 7. AI to help the technician (YES — native add-on OR DIY)
- **Native = Agentforce for Field Service** (§5): Pre-Work Brief, Knowledge Q&A, Post-Work Summary, scheduling, Siri. Polished but a **paid add-on** (~$125/user/mo add-on, or ~$550 "Agentforce 1 Edition for Field Service"; verify current SKU). **AI needs connectivity** — "offline-first" covers records, NOT the AI.
- **DIY on a base Agentforce/Einstein entitlement (no FS-specific add-on):**
  - **`GenAiPromptTemplate`** (Prompt Builder) grounded on `WorkOrder`/`Asset`/`ServiceAppointment` — e.g. *"summarize this work order for a pre-visit brief"*, *"draft service-report notes from these activities"*, *"suggest the next best step"*. Invoke from **Apex** (`ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate`), **Flow** (Prompt Template action), or **REST**, and surface it as a **mobile LWC/Flow quick action** on the Work Order.
  - **Custom Agentforce agent** (`GenAiPlanner`/`Bot` + `GenAiPlugin` topics + `GenAiFunction` Apex actions, via `sf agent`) for a richer conversational helper.
- **Gotchas:** `GenAiPromptTemplate` isn't SOQL-queryable (reference by name); deploy linked Flow/Apex **before** the template; grounding quality depends on **Data Cloud + Knowledge** being populated (ungrounded → hallucination); confirm prompt templates render on the **mobile** action layout (test on device).
- **⚠️ Verified (works on a base Agentforce/Einstein entitlement):** `ConnectApi.EinsteinLLM.generateMessages(new ConnectApi.EinsteinLlmGenerationsInput())` (set `.promptTextorId` + `.additionalConfig.applicationName='PromptBuilderPreview'`) returns LLM text from Apex — wrap it `@AuraEnabled` for a mobile LWC button (online-only). **Coverage gotcha:** guarding the LLM call with `Test.isRunningTest()` leaves those lines uncovered — a small class can dip under 75% (saw 73.3%); keep the class lean or add covered lines.

## 8. Mobile enhancement checklist (to "make it better")
- **Faster priming:** drop the date-picker range to ~7/7; add **Briefcase** rules for extra offline records (parts catalog, asset history) using indexed filters.
- **One-tap LWC quick actions:** a "Visit Assistant" (quote / collect payment / service report in one screen), or per-step status + photo + parts-consumed flows.
- **Device capabilities:** barcode-scan asset serials, document/photo capture, **NFC** asset tags, **geofence auto check-in** on arrival.
- **AI:** pre-visit brief + draft service-report notes + next-best-action (prompt template); knowledge Q&A.
- **Closeout:** per-Work-Type **service report templates** + **digital signature** capture; **collect payment** (Pay Now link or partner card reader).
- **Reachability:** **push notifications** (connected app) + **deep links** for new/changed appointments.
- **Punch-outs:** **App Extensions** to partner tools (payment terminal, inventory).
- **Config:** branding, required fields, quick-action ordering in **Field Service Mobile Settings**.

## Gotchas
- **DX-vs-UI for mobile config (verified, all three set live):** **`FieldServiceMobileSettings` and `FieldServiceSettings` are NOT metadata types** (`INVALID_TYPE: Unknown type`) — so the **priming date range** and **push notifications** are **Setup-UI-only** (the Field Service Mobile Settings *config record* → inline-edit; "Service Appointment Priming → Past/Future Days in the Date Picker" = priming, "Notification Settings → Send appointment notifications on assignment/dispatch" = push). The setup-detail page resists automated scroll — use `find`/JS `scrollIntoView` to reach off-screen fields, or resize the window taller.
- **`BriefcaseDefinition` metadata gotchas:** it IS a metadata type, BUT (a) **recipient/user-group assignments + app associations are NOT in the metadata** — they're set only in the **Briefcase Builder wizard** (Setup → *Offline → Briefcase Builder*; the setup node is `Briefcase`, NOT `BriefcaseBuilder`), so a metadata-only deploy is a **phantom no-op** (reports "Succeeded, 1 deployed" but the record never persists / isn't queryable). Create it in the wizard. (b) The rule schema is non-obvious — `briefcaseRules`: `targetEntity` (NOT `object`), `recordLimit` (NOT `maxRecords`), `queryScope` (`Everything`), `orderBy`, `isAscendingOrder`, `filterLogic`; `briefcaseRuleFilters`: `targetEntityField` (NOT `field`/`fieldName`), `filterOperator` (`e`=equals), `filterValue`, `filterSeqNumber`. Deep links (`fsl://`) are a usage pattern, not a deployable artifact.
- **Embedding LWC needs the "Enable the Lightning SDK … Field Service mobile app" permission** + the action on the page layout, or it won't show. Build offline-safe (LDS/uiGraphQLApi v1, getter-extracted query, `if:true` not `lwc:if`) — verify with the Salesforce MCP offline tools.
- **Mobile AI requires connectivity** (offline-first = records only). Native Agentforce for Field Service is a separate paid add-on; a DIY prompt-template helper runs on a base Agentforce/Einstein entitlement.
- **Two-layer mobile licensing**: Mobile PSL (login) ≠ Scheduling PSL (appears on Gantt) — a working tech needs both.
- **Resource must read itself** — share the worker their own `ServiceResource` (Read Only) or the app misbehaves.
- **Connected app is mandatory** for push + Briefcase/offline; both silently fail without it.
- **Priming ≠ Briefcase** — priming is auto/app-built (date-range tuned); Briefcase is admin-defined extra records.
- **Date-picker defaults ~45 days** → slow initial priming; drop to ~7/7.
- **Appointment Assistant**: install incognito, Admins Only, approve third-party access; doesn't work on TP sample data.
- **Three scheduling products** with overlapping shift concepts (Field Service / WFE / Salesforce Scheduler) — confirm which the org owns.
- **Separate licenses**: Appointment Assistant (FSA), Visual Remote Assistant, Workforce Engagement, Salesforce Scheduler, Agentforce — NOT part of base FSL.

Help slugs: `service.mfs_perms_standard.htm`, `service.fs_perm_set_licenses.htm`, `service.mfs_offline_parent.htm`, `service.mfs_push_notifications.htm`, `service.mfs_appointment_assistant_install_packages.htm`, `service.fs_intro_visual_assistance.htm`, `service.workforce_engagement_about_shift_scheduling_tools.htm`. Trailhead: `field-service-mobile`, `offline-briefcase`, `real-time-location-appointment-assistant`, `visual-remote-assistant`, `shift-creation-assignment`.
