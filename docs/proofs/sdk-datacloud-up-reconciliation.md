# SDK Browsing → Data Cloud → Unified Profile reconciliation — PROVEN (2026-06-13)

100% DX / headless (no UI, no custom Apex stitch, no connector wizard).

## Architecture (all official Data Cloud)
- Web SDK (c360a beacon) on storefront → sets `_sfid` cookie `anonymousId = deviceId`, auto-tracks page views.
- DLO→DMO maps (ObjectSourceTargetMap, deployed):
  - `Kwitko_Storefront_identity.deviceId → ssot__Individual__dlm.ssot__Id` (every device = a source Individual)
  - `Kwitko_Storefront_contactPointE.{email→EmailAddress, deviceId→Id, deviceId→PartyId}` (device carries its email)
  - `Kwitko_Storefront_Behavioral_Ev → Web_Event_c_Home__dlm` (deviceId→Account_c = Individual FK) — browsing events
- Identity Resolution ruleset `inCoffee Unified Profile` (id 1irfj000000fyoIAAQ):
  - Existing: "Fuzzy Name and Normalized Email"
  - ADDED via Connect REST PATCH (headless): "Normalized Email Only" on ssot__ContactPointEmail__dlm.ssot__EmailAddress__c
  - This was the fix: the device-Individual has email but NO name, so the name+email rule never matched it. Email-only rule merges it.
- Run: POST /ssot/identity-resolutions/<id>/actions/run-now  {}

## PROOF (real data)
device  fa28d802c90b0bbd     UnifiedRecordId 6ca1578d414d70dfe49572a9f82e0a5a
customer 001fj00001HIm5aAAD  UnifiedRecordId 6ca1578d414d70dfe49572a9f82e0a5a   <-- SAME UP
IR stats: unified 177, anonymous 1 (the device with no email stays anonymous, correct), consolidation 1.
Browsing events for the device are in Web_Event_c_Home__dlm (Account_c=deviceId) → roll up to the unified customer.

## Verify commands
sf api request rest "/services/data/v62.0/ssot/query" --method POST --body '{"sql":"SELECT SourceRecordId__c, UnifiedRecordId__c FROM UnifiedLinkssotIndividualCoff__dlm WHERE SourceRecordId__c IN (...)"}'

## REAL-WORLD TESTS (2026-06-13, live storefront, real c360a SDK)

Method note: Control_Chrome execute_javascript runs in an ISOLATED world (page globals invisible).
To read/fire the SDK identify hook, inject a <script> into the MAIN world and pass results back via a DOM attr.
Fresh "incognito" device = clear the `_sfid_35cb` cookie → c360a mints a new anonymousId (=deviceId).

### Test 1 — SDK browsing → Data Cloud  [PASS]
Original device fa28d802c90b0bbd: 84 browse events in Web_Event_c_Home__dlm (Account_c=deviceId), Individual exists.

### Test 2 — Incognito anonymous browse → identify by EMAIL → reconcile  [PASS]
- Cleared cookie → fresh device 63bea34a3d0a6ef3 → browsed home/shop/product.
- Anonymous browsing landed in Data Cloud in ~2 min (3 behavioral + 3 engagement-DMO rows + anonymous Individual).
- Fired window.kwitkoIdentify('alexkwitko@gmail.com') (main-world) → contactPointEmail event → run-now IR.
- RESULT: fa28d802 (old dev) + 63bea34a (new dev) + 001fj00001HIm5aAAD (CRM customer) ALL → UnifiedRecordId 6ca1578d414d70dfe49572a9f82e0a5a. Cross-device + anonymous→known reconciliation CONFIRMED.

### Test 3 — fresh device → identify via CHAT hook (different customer)  [PASS]
- Chat sign-in snippet (kwitko-chat-identity-fix.php) calls the SAME window.kwitkoIdentify hook (verified).
- Fresh device 3a0b137b6e827b2d → browsed → fired kwitkoIdentify('consenttest@example.com') (the chat hook) → IR.
- Expected: 3a0b137b6e827b2d reconciles to customer 001fj00001HIhNdAAL's UnifiedRecordId.

## IR cadence (current as of 2026-06-15)
doesRunAutomatically=True and lastJobStatus=SUCCESS. Manual run-now is still useful for an immediate test,
but production reconciliation no longer depends on a human/API-triggered run.

### Test 3 RESULT [PASS]
3a0b137b6e827b2d (chat-identified device) + 001fj00001HIhNdAAL (customer) → SAME UnifiedRecordId 1c4e25a3248bc3629db091d8e3f64882.
ALL 3 TESTS PASS. Anonymous browse → Data Cloud → identify (email OR chat) → Identity Resolution → Unified Profile, official + headless.

## PROFILE ENRICHMENT (2026-06-13)
### Calculated Insight keyed to Unified Individual — WORKS headlessly [PASS]
Created via Connect API POST /ssot/calculated-insights (NOT the silent-fail metadata path):
`UP_Web_Engagement__cio` — dimension UnifiedIndividualId__c (formula = UnifiedLinkssotIndividualCoff__dlm.UnifiedRecordId__c),
measures WebEventCount__c + LastWebActivity__c, joining Web_Event_c_Home__dlm → UnifiedLink → Unified Individual.
RESULT: unified individual 6ca1578d... = 130 web events (aggregated across stitched devices).
KEY: a CI only shows on Profile Explorer if its dimension is the UNIFIED INDIVIDUAL ID (source CIs keyed on AccountId/text do NOT show).

### Ecommerce / service related lists + CIs — BLOCKED (Data Cloud UI-gated)
Orders/Cases/Returns are lake-only DLOs; CIs/related-lists need them as DMOs. DMO-create via Connect API GACKS
(UNKNOWN_EXCEPTION); federating into the empty Order_Analytics DMO fails on Number-vs-Currency type clash.
=> creating those DMOs needs the Data Cloud "New Data Model Object" UI wizard; after that the CIs/relationships are headless.
Headless alternative already live: CustomerInsightsService writes LTV/AOV/RFM/taste/cases/returns onto the CRM Account 360.

## ENRICHMENT BREAKTHROUGH (2026-06-13) — ecommerce/service on the profile, HEADLESS
Earlier I concluded Order/Case related-lists were UI-blocked (custom DMO create GACKS). The fix: **map the CRM DLOs into the STANDARD Data Cloud DMOs** (which exist as definitions), which the mapping API accepts (no custom-DMO create needed):
- `Order_Home__dll → ssot__SalesOrder__dlm` (Id, AccountId→SoldToCustomerId, TotalAmount→GrandTotalAmount[Number-to-Number, no currency clash], EffectiveDate→PurchaseOrderDate, OrderNumber) — **materialized 390 rows**, keyed to customers.
- `Case_Home__dll → ssot__Case__dlm` (Id, AccountId→IndividualId & →AccountId, CreatedDate, CaseNumber, Subject) — **34 rows**.
- `ReturnOrder_Home__dll → ssot__ReturnOrder__dlm` (Id, AccountId→CustomerAccountId, CreatedDate, GrandTotalAmount, ReturnOrderNumber).
Then surfaced on the Unified Individual via the PROVEN CI pattern (keyed on UnifiedIndividualId, joined through UnifiedLink): `UP_Customer_Value` (order count, LTV, AOV, last order FROM ssot__SalesOrder__dlm) + `UP_Service_Profile` (case count, last case FROM ssot__Case__dlm) + existing `UP_Web_Engagement`. **All headless via POST /ssot/calculated-insights.**
Current proof for unified individual `6ca1578d414d70dfe49572a9f82e0a5a`:
- `UP_Customer_Value__cio`: 7 orders, 886.10 LTV, 126.585714 AOV, last order 2026-06-14.
- `UP_Web_Engagement__cio`: 130 events, last activity 2026-06-14T19:33:21.83Z.
- `UP_Web_Engagement_Device_Profile__cio`: 148 SDK web events, 6 devices, 17 sessions, 21175 dwell seconds, last activity 2026-06-15T01:13:09.784Z.
- `UP_Service_Profile__cio`: 21 cases, last case 2026-06-15T04:29:36Z.
- Underlying row-level DMOs are populated too: `ssot__SalesOrder__dlm` = 15 rows, `ssot__Case__dlm` = 6 rows, `Web_Event_c_Home__dlm` = 75 rows as of the latest `2026-06-15T08:17Z` verifier.

### Profile display / related-list enrichment status — CURRENT (2026-06-15)

The data exists and the CIs compute, so a missing Profile Explorer/record-page display is not an ingestion failure.

- CI objects exist in the org: `UP Customer Value`, `UP Web Engagement`, `UP Web Engagement Device Profile`, and `UP Service Profile`.
- CI rows return for unified individual `6ca1578d414d70dfe49572a9f82e0a5a`.
- Row-level DMOs expose relationship keys usable for enrichment:
  - `ssot__SalesOrder__dlm.ssot__SoldToCustomerId__c` contains the source Account id.
  - `ssot__Case__dlm.ssot__IndividualId__c` and `ssot__Case__dlm.ssot__AccountId__c` contain the source Account/Individual id.
- The missing piece is the Salesforce UI/enrichment layer: configure Data Cloud related-list/copy-field enrichment or the Data 360 Profile Related Records Lightning app so the computed insights and row-level DMOs are surfaced where the user expects them.
- CRM-side Account fallback is current: Alex's Person Account has `Insights_Order_Count__c=7`, `Insights_LTV__c=886.1`, `Insights_Web_Events__c=148`, `Insights_Device_Count__c=6`, `Insights_Session_Count__c=17`, `Insights_Total_Cases__c=21`, `Insights_Returns__c=3`, and `Data_Cloud_Unified_Individual_Id__c=6ca1578d414d70dfe49572a9f82e0a5a`.
REMAINING nicety: the per-record RELATED LIST (vs CI metrics) needs a DMO→Individual relationship; `POST /ssot/data-model-objects/{dmo}/relationships` has an undocumented input rep (every guessed field rejected) — the CI metrics deliver the business value without it. Standard SalesOrder relates to Account/ContactPointEmail/etc. but not Individual directly.
