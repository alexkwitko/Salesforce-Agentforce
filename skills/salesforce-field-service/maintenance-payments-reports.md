# Maintenance plans, payments & service reports

Three revenue/closeout capabilities on top of core Field Service. **All object/field API names below were verified in a live org (June 2026)** — they differ from the public docs in a few places (flagged ⚠️). The standard `generateWorkOrders` and `createServiceReport` operations are **platform Actions, not DML** — the #1 mistake is trying to `insert` your way to a generated work order or PDF.

---

## 1. Maintenance Plans → recurring/preventive maintenance, sold as a subscription

Auto-generate WorkOrders + ServiceAppointments on a recurring schedule for one or more Assets. Three standard objects (all DX-createable via `sf data create` / Apex / Composite API):

### Data model (org-verified fields)
- **`MaintenancePlan`** — the master schedule.
  - `StartDate`, `EndDate`, `WorkTypeId` (→ WorkType: duration/skills/products inherited by generated WOs), `AccountId`, `ContactId`, `ServiceContractId` (→ ServiceContract — the subscription link; visible only with Entitlement Management on).
  - **Generation knobs:** `GenerationTimeframe` (int) + `GenerationTimeframeType` (`Days|Weeks|Months|Years`) = how far *ahead* each batch is generated; `GenerationHorizon` (int) = how many days *before* the first WO's date the batch fires; `DoesAutoGenerateWorkOrders` (bool, daily background job); `DoesGenerateUponCompletion` (bool, generate next batch when the current batch's last WO closes); `WorkOrderGenerationStatus` (`NotStarted|InProgress|Complete|Unsuccessful|NoWorkOrderGenerated|NeedsReview`).
  - **Shape of output:** `WorkOrderGenerationMethod` (`WorkOrderPerAsset|WorkOrderLineItemPerAsset`) + `SvcApptGenerationMethod` (`SvcApptPerWorkOrder|SvcApptPerWorkOrderLineItem`).
  - ⚠️ **`Frequency`/`FrequencyType` were RETIRED Oct 1, 2025** — they no longer exist on the object (verified absent). Recurrence now lives **only** in `MaintenanceWorkRule`. Any old automation/report referencing them is broken.
- **`MaintenanceAsset`** — junction Asset↔plan. Fields: `MaintenancePlanId`, `AssetId`, optional per-asset `WorkTypeId`, `NextSuggestedMaintenanceDate`. One Asset can sit on many plans.
- **`MaintenanceWorkRule`** — the recurrence engine (replaced the old frequency fields). Fields: **`RecurrencePattern`** (string = an iCalendar **RRULE**, e.g. `FREQ=MONTHLY;INTERVAL=3` for quarterly) and ⚠️ **`ParentMaintenancePlanId`** (NOT `MaintenancePlanId`). Salesforce Labs' "Maintenance Work Rule Editor" writes the RRULE for you, but the field is plain API-settable.

### Generating the work orders
- **Auto:** `DoesAutoGenerateWorkOrders = true` → daily batch job creates the next batch per the RRULE + horizon; `NextSuggestedMaintenanceDate`/`MaintenanceAsset.NextSuggestedMaintenanceDate` auto-advance.
- **Manual / programmatic:** the **`generateWorkOrders` standard Action** — `POST /services/data/vXX.0/actions/standard/generateWorkOrders` with `{"inputs":[{"maintenancePlanIds":["<id>"]}]}` (or Flow's "Generate Work Orders" action). ⚠️ **Not DML, and not callable when `DoesAutoGenerateWorkOrders=true`** (toggle auto off first). ⚠️ Not supported in Apex tests — mock it. Each generated WO/WOLI inherits the WorkType and carries the Asset; ServiceAppointments still need the **managed-package optimizer/Dispatcher Console** to actually get scheduled.

### Selling it as a subscription (3 paths, pick by what you already own)
1. **Service Contracts + Entitlements (native Service/FSL).** Sell a `ServiceContract` (term + dates) with `ContractLineItem`s/`Entitlement`s, link `MaintenancePlan.ServiceContractId`. The plan delivers the contracted visits. *License:* Service Cloud + **Entitlement Management** enabled. ⚠️ This models the agreement and the visits — it does **NOT bill**; pair with manual invoicing or path 2/3. Best when you're already on FSL/Service Cloud.
2. **Revenue Cloud / Revenue Lifecycle Management (Subscription Mgmt + Billing).** Model the recurring SKU as `Order`/`OrderItem` (termed or evergreen) with billing schedules → `Invoice`/`InvoiceLine`, proration, renewals. *License:* separate paid product (RLM). Bridge to delivery by creating/linking a `MaintenancePlan` when the subscription activates. Best when maintenance is a true recurring-revenue product needing automated billing.
3. **Order/Contract + scheduled billing (lightweight).** Standard `Contract`/`Order` for the commercial side + a scheduled Flow/Apex to raise charges/renewals; MaintenancePlan handles delivery. No extra license. Best for simple needs without RLM cost.

### RLM ↔ Maintenance Plans ↔ Field Service Assets (the cross-cloud model)
The **`Asset` (install base) is the shared backbone** — Revenue Cloud / RLM **creates and time-slices** it; Field Service **consumes** it:
```
RLM            Quote → Order → ASSET (+ AssetStatePeriod, AssetAction)   ← the subscription / install base
                                   │
BRIDGE         ServiceContract + Entitlement + ContractLineItem.AssetId   ← "what coverage is owed"
                                   │  (MaintenancePlan.ServiceContractId)
FIELD SERVICE  MaintenancePlan ─(MaintenanceAsset.AssetId)→ recurring WorkOrders → ServiceAppointments
```
**Flow:** sell (RLM Quote→Order) → provision the `Asset` (+ first `AssetStatePeriod`) → wrap coverage in a `ServiceContract`/`Entitlement` (asset-based via `ContractLineItem.AssetId`) → `MaintenancePlan` (linked via `ServiceContractId`) generates recurring WOs on an RRULE → Field Service schedules/completes → renew/amend in RLM creates a new `AssetStatePeriod`.
Three load-bearing facts:
- **Maintenance-as-subscription** = an RLM recurring `ProductSellingModel` product whose `Asset` is covered by a `ServiceContract`, delivered by a `MaintenancePlan`. (The FSL half is proven — a plan sold as a ServiceContract + activated Order.)
- **`MaintenancePlan.ServiceContractId` is hidden unless Entitlement Management is on** — it's the single field tying the sold contract to the recurring visits.
- **Renewal coupling is custom** — renewing/amending an RLM Asset does **not** auto-extend the MaintenancePlan/ServiceContract; build a Flow/Apex on **`AssetAction.Category`** (renew/amend/cancel) to extend coverage + regenerate (or stop) work orders.
- ⚠️ **RLM headless-engine enablement reality (verified, Developer Edition 2026):** Setup → Subscription Management → General Settings can show *"Access Subscription Management Features = Active"* + *"New Order Save Behavior"* ON, yet the **Place Quote API still returns `FUNCTIONALITY_NOT_ENABLED [PlaceQuoteApplication]`** and Salesforce Pricing is un-provisionable (PSL Disabled+0). There is **no self-service "Enable Revenue Cloud Features" toggle** — the headless transaction/pricing engine needs **Salesforce-side provisioning**. Workaround: drive the lifecycle directly on **`Asset`/`AssetStatePeriod`/`AssetAction`** (the "Asset-path"), a drop-in for the engine if/when it's provisioned. Full quote-to-cash detail (Place Quote/Order, Salesforce Pricing, AssetAction amend/renew/cancel): see the **[[salesforce-rlm]]** skill.

### Gotchas
- Auto-generate ON ⇒ the `generateWorkOrders` Action errors — toggle off for manual runs.
- Oversized `GenerationTimeframe` floods the org with future WOs ("surprise backlog").
- No `WorkType` ⇒ empty generated WOs (no duration/skills).
- Plans only *create* the work; scheduling the SAs still needs the optimizer/console.

---

## 2. Technicians accepting & managing payments

⚠️ **Two honesty callouts up front:** (a) Field Service has **no native invoice** generated from a WorkOrder, and (b) the Field Service mobile app has **no native in-app card swipe**. The native answer to "collect payment on site" is a **Pay Now payment link** the customer pays on their own phone — *not* a card reader in the tech's app.

### What IS native
- **WorkOrder pricing (not an invoice).** `WorkOrder` is price-book aware: `Pricebook2Id`, and rollup `Subtotal`/`Discount`/`Tax`/`TotalPrice`/`GrandTotal`. `WorkOrderLineItem` carries `PricebookEntryId`/`Quantity`/`UnitPrice`/`Discount`/`Subtotal`/`TotalPrice` and rolls **up** to the WO. ⚠️ The WO rollup fields are computed/read-only — set amounts on the **line items**. This gives you the job total to charge, but FSL emits no `Invoice` record on its own.
- **Payment data model (`CommercePayments`, org-wide — not Commerce-only).** `PaymentGateway`/`PaymentGatewayProvider` (gateway adapter), `PaymentAuthorization` (auth/hold), `Payment` (capture/sale), `Refund`, `PaymentGroup`. ⚠️ In this org `PaymentGateway`/`PaymentAuthorization`/`Payment` exist but **`PaymentLink` does NOT** → **Pay Now / Salesforce Payments is not enabled by default**; it's a separate Setup enablement + (Stripe-backed) merchant onboarding.

### How teams actually do "tech collects on site" (ranked)
1. **Native Pay Now link from the WorkOrder/Service Report** *(best native fit)* — a Flow/quick action mints a `PaymentLink` for the WO `GrandTotal`; tech texts/emails it; customer pays on their phone before the tech leaves. Wireable into **Appointment Assistant** (native FSL→Pay Now integration). Requires Salesforce Payments enabled.
2. **AppExchange partner app** — **Blackthorn Payments** / **Chargent** ship FSL-mobile actions; Blackthorn additionally does **Bluetooth card-reader / card-present swipe in the mobile app** (the in-app capture Salesforce itself lacks). Use when you need terminal hardware or saved cards.
3. **Custom gateway** (Stripe/Square via a `CommercePayments` Apex adapter or REST) surfaced as a **mobile LWC quick action**.
4. **Mark-paid + external terminal** — run a standalone Square/Stripe terminal, then set a `Status`/custom `Paid__c` on the WO. Cheapest, manual reconciliation.

### Invoicing
- No FSL-native invoice. Formal `Invoice`/`InvoiceLine` need **Revenue Cloud / RLM Billing** (separate license; both objects exist in this org but are driven by billing schedules from Orders/Quotes, **not** auto-made from a WorkOrder). Most field shops skip formal Invoices and use the **Service Report** (below) + a **Pay Now link** as the customer-facing bill.

### Mobile specifics & gotchas
- **LWC Quick Actions** on WorkOrder/SA can launch a payment UI (enable the Lightning Web Runtime for the FSL mobile app, online + offline). **App Extensions** punch out to a partner/web checkout and return; **Deep Linking** (`fsl://`, ≤1MB payload) hands the WO id/amount to a flow.
- **Payment capture is online-only** (gateway callout) — won't work offline; gate the action on connectivity or queue it.
- "Field Service collects payments" almost always means the **Pay Now link**, not a card reader. **Card-present in-app = partner-only.** PCI scope sits with the gateway/partner, not FSL.

---

## 3. Service Reports + digital signatures (job closeout)

Branded job-sheet PDFs (signed by customer + technician), generated mostly on the **Field Service mobile app**. ⚠️ Template *design* is **Setup-UI-only** (see metadata note).

### Data model (org-verified — differs from public docs)
- **`ServiceReport`** — the generated document. `ParentId` (polymorphic → **WorkOrder, WorkOrderLineItem, or ServiceAppointment**), ⚠️ **`Template`** (a **string** = the template name — there is **no** `TemplateId` reference field), `ServiceReportLanguage` (picklist of locales: `en_US`, `fr`, `de`, `es`, `pt_BR`, …), and the PDF itself in **`ContentVersionDocumentId`** (→ ContentVersion/Files) **and** `DocumentBody` (base64) + `DocumentContentType`/`DocumentLength`/`DocumentName`. Auto-number `Name`.
- **`DigitalSignature`** — a signature on a service report. ⚠️ `ParentId` → the **ServiceReport** (signatures hang off the report, not the WO). Signer name = **`SignedBy`** (string), **`SignedDate`** (datetime), `DeviceType`, and the signature **image inline in `DocumentBody`** (base64) + `DocumentContentType`. ⚠️ **`SignatureType` is a picklist whose only value is `Default`** — the customer-vs-technician distinction comes from the **signature *blocks* in the template**, not from this field. Auto-number `DigitalSignatureNumber`.

### Templates (`ServiceReportLayout`)
- Built in **Setup → Field Service → Service Report Templates** (drag-and-drop editor): Header/Footer with logo (branding), **sections**, **related lists** (WOLIs, Products Consumed, Service Appointments, Time Sheets, Expenses), and **Signature blocks** (each block → a `DigitalSignature` capture slot; add one block per signer, e.g. Customer + Technician). Sub-templates exist per parent level (WO / WOLI / SA).
- **Assignment:** org default in **Field Service Settings**, overridable per **Work Type** via its **Service Report Template** field.
- ⚠️ **`ServiceReportLayout` is NOT in the `sf` CLI metadata registry** (`Missing metadata type definition in registry for id 'ServiceReportLayout'` — verified) → you **cannot** retrieve/deploy templates with stock `sf project retrieve/deploy`. Template design is **Setup-UI-only**; the records (`ServiceReport`/`DigitalSignature`) are normal data, queryable via SOQL.

### Generating & sharing
- **UI/Mobile:** the **Create Service Report** quick action on WorkOrder/WOLI/SA. On mobile the worker taps it, captures signatures on the touchscreen, previews, and the PDF generates (works offline, finalizes on sync). A **custom Flow** can override the standard button to gate steps before signature/generation.
- **Programmatic:** the **`createServiceReport` standard Action** (Invocable/Connect REST) — `POST /services/data/vXX.0/actions/standard/createServiceReport` with `parentId`, `template` (name), `serviceReportLanguage`. ⚠️ **Not DML** — you can't `insert` a `ServiceReport` and get a rendered PDF; you must call the Action.
- **Email/share:** attach the resulting **ContentVersion** PDF to an email — Apex `Messaging.EmailFileAttachment` from the ContentVersion, or a Flow/Email quick action on the parent.

### Gotchas
- Reports are **snapshots** — editing the template does NOT change already-generated PDFs; regenerate.
- Wrong/absent template on the Work Type ⇒ worker gets the org-default or a blank report — assign per Work Type.
- Signature isn't reusable — captured per report; image is its own base64/ContentVersion.
- Large related lists ⇒ slow generation + Files-storage bloat.
- `createServiceReport` is an **Action, not DML** (the recurring programmatic mistake).

---

### Enablement summary
| Capability | Needs |
|---|---|
| Maintenance Plans | Field Service enabled (managed package to *schedule* the output); Entitlement Mgmt for the `ServiceContractId` link |
| Subscription billing | Revenue Cloud / RLM (separate license) — or Service Contracts (agreement only) — or custom |
| Pay Now payment links | **Salesforce Payments** enablement + merchant (Stripe) onboarding (not on by default; `PaymentLink` absent until enabled) |
| In-app card swipe | Partner app (Blackthorn) — not native |
| Service Reports + signatures | Field Service + managed package + mobile app + Mobile PSL; template design is Setup-UI-only |

### Build gotchas (verified end-to-end in a live org, June 2026)
- **`generateWorkOrders` action input is `recordId`** (singular ID of the plan), NOT `maintenancePlanIds`. It's **async** — returns "in progress"; poll `MaintenancePlan.WorkOrderGenerationStatus` until `Complete`, then query the WOs. Generated 5 quarterly WOs + 1 SA each from `RecurrencePattern='FREQ=MONTHLY;INTERVAL=3'`.
- **MaintenancePlan generation-method combo is validated:** `WorkOrderGenerationMethod='WorkOrderPerAsset'` + `SvcApptGenerationMethod='SvcApptPerWorkOrder'` was REJECTED ("change one … to None"); `WorkOrderLineItemPerAsset` + `SvcApptPerWorkOrder` works (and gives you a WOLI per asset — handy for pricing).
- **Quotes must be enabled first** — `QuoteLineItem`/`Quote` aren't usable in Apex until you deploy `Settings:Quote` with `<enableQuote>true`; otherwise "Invalid type: Schema.QuoteLineItem".
- **One `@InvocableMethod` per Apex class** — split Collect-Payment and Generate-Quote into separate classes (each a separate Flow/quick action).
- **`PaymentGroup.SourceObjectId` only accepts an Order** (not WorkOrder) — insert a bare `new PaymentGroup()` and link the WO via `Payment.Comments`/your own field. `Payment` inserts directly with `ProcessingMode='External'`, `Type='Sale'`, `Status='Processed'`, `Amount`, `AccountId`, `PaymentGatewayId` (records an on-site collection without keying card data).
- **`DigitalSignature.ParentId` does NOT accept a ServiceReport** — only `WorkOrder`, `WorkOrderLineItem`, `ServiceAppointment`, `Order`, `Quote`, `AuthorizationFormConsent`. Sign against the **WorkOrder**; the report renders its parent's signatures. `SignatureType` picklist = `Default` only; image goes in `DocumentBody` (base64). `ServiceReport.Template` is the template Id as a string; PDF is in `ContentVersionDocumentId`.
- **`createServiceReport` action works with NO `templateId`** (uses the org default template) — input is `entityId` (WO/WOLI/SA) + optional `templateId`/`language`/`signatures`; returns `serviceReportId` + `contentVersionId` (the PDF).
- **New custom fields aren't SOQL-readable until FLS is granted** even for the deploying admin — Apex (system context) writes them fine, but `sf data query` returns "No such column" until you add `FieldPermissions` via a permission set. (Hit on `WorkOrder.Payment_Status__c`/`Amount_Collected__c`.)
- **Test-context gotchas:** `OpportunityStage` and the standard `Pricebook2` (`WHERE IsStandard=true`) return **0 rows** in Apex tests — fall back to a literal stage (`'Prospecting'`) and use `Test.getStandardPricebookId()` (guard with `Test.isRunningTest()`).

Sources: Field Service & Object Reference dev guides (`MaintenancePlan`/`MaintenanceAsset`/`MaintenanceWorkRule`/`ServiceReport`/`DigitalSignature`/`WorkOrderLineItem`/`Payment*`), `generateWorkOrders` & `createServiceReport` Action guides, Salesforce Payments / Pay Now (Trailhead + Appointment Assistant payments), Revenue Cloud Billing. Field names verified against a live org via `sf sobject describe` (June 2026).
