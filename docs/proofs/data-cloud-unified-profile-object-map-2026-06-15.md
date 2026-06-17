# Kwitko Data Cloud / Unified Profile Object Map - 2026-06-15

Current proof target: `alexkwitko@gmail.com`

## Current Verdict

The underlying Data Cloud data is present and joined to the Unified Profile. The current gap is not ingestion or Identity Resolution; it is the visual Data Cloud Profile Explorer/enrichment surface for calculated-insight panels and row-level related-list display.

Latest verifier:

```bash
./tools/verify_unified_profile_surface.sh AgentforceDev alexkwitko@gmail.com
```

Result: `41 passed, 0 failed, 1 warning`.

## Identity Resolution

| Check | Current Evidence |
|---|---|
| CRM Account | `001fj00001HIm5aAAD` / `Alex Web` / `alexkwitko@gmail.com` |
| Cached Unified Individual | `6ca1578d414d70dfe49572a9f82e0a5a` |
| UnifiedLink | Account source maps to the same unified id |
| IR schedule/status | Auto-run is enabled; latest checked job was `SUCCESS` |
| Email/device collapse | Existing email/device source rows collapse to the same unified profile in the safe runner |

## Source To Data Cloud Map

| Business Area | CRM / SDK Source | Data Cloud Object(s) | Purpose |
|---|---|---|---|
| Person identity | `Account` / `Account_Home__dll` | `ssot__Individual__dlm` | Profile hub and coffee preferences |
| Email identity | `Account` / storefront identity/contact point DLOs | `ssot__ContactPointEmail__dlm` | Email match key and Individual relationship |
| Orders | `Order` / `Order_Home__dll` | `ssot__SalesOrder__dlm` | Customer value, last order, row-level order history |
| Service | `Case` / `Case_Home__dll` | `ssot__Case__dlm` | Service profile, case counts, row-level case history |
| Returns | `ReturnOrder` / `ReturnOrder_Home__dll` | `ReturnOrder_Home__dlm` | Return/refund risk and return history |
| Web activity | Data Cloud Web SDK + `Web_Event__c` stream | `Web_Event_c_Home__dlm` | Browsing, device/session/dwell, category/product affinity |

Important source-controlled metadata:

- `force-app/main/default/objectSourceTargetMaps/Account_Home_map_Individual_1780619884966.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Account_Home_map_ContactPointEmail_1780619893796.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Kwitko_identity_map_Individual.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Kwitko_email_map_ContactPointEmail.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Web_Event_c_Home_map_Web_Event_c_Home_1781273123060.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Case_Home_map_Case_Home_1780782195682.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/Order_Home_map_Order_Home_1780619305244.objectSourceTargetMap-meta.xml`
- `force-app/main/default/objectSourceTargetMaps/ReturnOrder_Home_map_ReturnOrder_Home_1780782195693.objectSourceTargetMap-meta.xml`

## Unified Profile Calculated Insights

| Calculated Insight | Status | Runtime Evidence For Unified Id |
|---|---|---|
| `UP_Customer_Value__cio` | `ACTIVE`, last run `SUCCESS` | `7` orders, `$886.10` LTV, `$126.585714` AOV |
| `UP_Web_Engagement__cio` | `ACTIVE`, last run `SUCCESS` | `130` web events |
| `UP_Web_Engagement_Device_Profile__cio` | `ACTIVE`, materialized rows | `148` SDK events, `6` devices, `17` sessions, `21175` dwell seconds |
| `UP_Service_Profile__cio` | `ACTIVE`, last run `SUCCESS` | `21` cases |

Source-controlled CI definitions:

- `force-app/main/default/mktCalcInsightObjectDefs/UP_Customer_Value.mktCalcInsightObjectDef-meta.xml`
- `force-app/main/default/mktCalcInsightObjectDefs/UP_Web_Engagement.mktCalcInsightObjectDef-meta.xml`
- `force-app/main/default/mktCalcInsightObjectDefs/UP_Web_Engagement_Device_Profile.mktCalcInsightObjectDef-meta.xml`
- `force-app/main/default/mktCalcInsightObjectDefs/UP_Service_Profile.mktCalcInsightObjectDef-meta.xml`

## Row-Level Unified Profile Joins

The verifier proves row-level DMO data joins back to the Unified Individual:

| Row Type | Current Joined Row Count |
|---|---:|
| `ssot__SalesOrder__dlm` | `6` |
| `ssot__Case__dlm` | `8` |
| `Web_Event_c_Home__dlm` | `57` |

This means the data needed for related order/case/web lists exists in Data Cloud. The remaining issue is whether the Data Cloud Profile Explorer visual configuration exposes those rows as related lists.

## Person Account Augmentation

Current CRM Account cache for `Alex Web`:

| Field | Value |
|---|---|
| `Data_Cloud_Unified_Individual_Id__c` | `6ca1578d414d70dfe49572a9f82e0a5a` |
| `Data_Cloud_Insight_Source__c` | `Data Cloud Unified CI + CRM fallback` |
| `Insights_Order_Count__c` | `7` |
| `Insights_LTV__c` | `886.1` |
| `Insights_AOV__c` | `126.585714` |
| `Insights_Web_Events__c` | `148` |
| `Insights_Device_Count__c` | `6` |
| `Insights_Session_Count__c` | `17` |
| `Insights_Total_Cases__c` | `21` |
| `Insights_Returns__c` | `3` |
| `Insights_Taste_Profile__c` | `Single-Origin` |
| `Insights_RFM_Segment__c` | `VIP` |

The Account record page/layout source contains the Account insight fields and Data Cloud source/id fields, so the CRM Account 360 surface is source-controlled. The Data Cloud Profile Explorer visual panel still needs UI certification.

## Remaining Gaps

1. WPCode snippet `305` is now live as bridge `20260615.12`; storefront browser identity/cart/OTP/return-label routes still need fresh widget/API certification from a browser or network path that can operate the cross-origin Salesforce iframe and reach the REST endpoints.
2. Data Cloud Profile Explorer related-list/calculated-insight visual configuration is not proven by headless checks; data and joins are proven.
3. Prediction has historical output and a successful prediction job, but no API-visible active Model Builder definition/model in `MLPredictionDefinition`, `MktMLModel`, or `MLModel`.
