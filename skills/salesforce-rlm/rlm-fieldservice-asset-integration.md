# RLM ↔ Field Service ↔ Assets — Quote-to-Cash-to-Service-to-Renew

The **`Asset`** (install base) is the shared backbone across clouds. **Revenue Cloud / RLM creates and time-slices** the Asset; **Field Service consumes** it to deliver maintenance. The bridge between "sold subscription" and "delivered service" is **`ServiceContract` + `Entitlement` + `MaintenancePlan`**. Pair this file with the `salesforce-field-service` skill for the FSL side.

## The shared backbone (object map)
```
 RLM (owns install base)                         FIELD SERVICE (consumes install base)
 Quote→Order→ Asset ◀─Product2                   MaintenancePlan ─(MaintenanceAsset.AssetId)─▶ Asset
   QuoteLineItem/OrderItem                          │ WorkTypeId, ServiceContractId, StartDate/EndDate
     .ProductSellingModelId (recurring)             │ Generation* knobs, DoesAutoGenerateWorkOrders
        │                                           ├─ MaintenanceWorkRule.RecurrencePattern (RRULE)
   Asset lifecycle:                                 └─(generateWorkOrders, async)─▶ WorkOrder
     AssetStatePeriod (StartDate/EndDate,Qty,Mrr)        └─ WorkOrderLineItem (AssetId)
     AssetAction (Category New/Amend/Renew/Cancel)            └─ ServiceAppointment → AssignedResource
       AssetActionSource → OrderItem                              (scheduled by optimizer/Dispatcher)
     AssetContractRelationship (Asset↔Contract, v60+)
                 │
        BRIDGE:  ServiceContract ◀(ContractLineItemId) ContractLineItem ─(AssetId)─▶ Asset
                   └ Entitlement (term + work-type/SLA)         MaintenancePlan.ServiceContractId ──┘
```

## Asset = the join
- **RLM creates it:** `Order` activation → **`Asset`** (the persistent install-base record) + first **`AssetStatePeriod`** + **`AssetAction`**(New) + **`AssetActionSource`**→`OrderItem`. Key fields RLM populates and FSL reads: `Product2Id`, `SerialNumber`, `AccountId`, `ContactId`, `LifecycleStartDate`/`LifecycleEndDate`/`CurrentLifecycleEndDate`, `Quantity`, `Status`, `RootAssetId`/`ParentId` (hierarchy), `CurrentMrr`/`TotalLifecycleAmount`.
- **FSL consumes it:** `WorkOrder.AssetId` / `WorkOrderLineItem.AssetId` = the installed product serviced; `MaintenanceAsset` (junction `MaintenancePlanId`+`AssetId`) puts the Asset on a plan; `ServiceAppointment.ParentRecordId` (polymorphic) can point at WO/WOLI/**Asset**.
- **`AssetContractRelationship`** (v60+) links Asset↔Contract; **`ContractLineItem.AssetId`** makes a contract line asset-based.

### Lifecycle mechanics (memorize)
| AssetAction.Category | AssetStatePeriod | Quote/Order line |
|---|---|---|
| **New** | first period | positive qty |
| **Amend** (up/down) | **new** period, old closes at amend date | positive/negative **delta** |
| **Renew** | **new** period, extended term | positive, new term |
| **Cancel** | **ends** period — no new one | **negative** qty |

## Maintenance Plans → recurring Work Orders (FSL)
- **`MaintenancePlan`** = master schedule. Fields: `WorkTypeId`, `AccountId`, `ContactId`, `StartDate`/`EndDate`, **`ServiceContractId`** (the subscription link — **only visible when Entitlement Management is enabled**), `GenerationTimeframe`+`GenerationTimeframeType`(`Days|Weeks|Months|Years`), `GenerationHorizon`, `DoesAutoGenerateWorkOrders`, `WorkOrderGenerationStatus`, `WorkOrderGenerationMethod`(`WorkOrderPerAsset|WorkOrderLineItemPerAsset`), `SvcApptGenerationMethod`(`SvcApptPerWorkOrder|SvcApptPerWorkOrderLineItem`).
- **`MaintenanceAsset`** = junction Asset↔plan (`MaintenancePlanId`, `AssetId`, optional per-asset `WorkTypeId`, `NextSuggestedMaintenanceDate`). 3 assets × monthly = 3 WOs/month with `WorkOrderPerAsset`.
- **`MaintenanceWorkRule`** = recurrence engine: **`RecurrencePattern`** (iCal RRULE, e.g. `FREQ=MONTHLY;INTERVAL=3`), parent field **`ParentMaintenancePlanId`** (NOT `MaintenancePlanId`). ⚠️ The old `Frequency`/`FrequencyType` fields were **RETIRED Oct 1, 2025** — recurrence lives only here.
- **Generate:** auto (daily batch when `DoesAutoGenerateWorkOrders=true`) or **`generateWorkOrders`** standard action (`POST /services/data/vXX.0/actions/standard/generateWorkOrders`, input **`recordId`** = plan id) — **async** (poll `WorkOrderGenerationStatus` to `Complete`), **not DML**, and **blocked while auto-gen is on** (toggle off first). ⚠️ Combo `WorkOrderPerAsset`+`SvcApptPerWorkOrder` is rejected — use `WorkOrderLineItemPerAsset`+`SvcApptPerWorkOrder`.
- Generated WOs inherit `WorkType` + carry `AssetId`; the resulting `ServiceAppointment`s **still need the managed-package optimizer/Dispatcher Console to be scheduled** — the plan only *creates* the work.

## Selling maintenance AS a subscription (the bridge) — three paths
1. **ServiceContract + Entitlements** (agreement only, no billing): `ServiceContract` + `ContractLineItem`(`AssetId`) + `Entitlement`; link `MaintenancePlan.ServiceContractId`. License: Service Cloud + **Entitlement Management**.
2. **RLM full quote-to-cash** (recurring revenue + billing): maintenance SKU = `Product2` + recurring `ProductSellingModel` → Quote→Order→`Asset`+`AssetStatePeriod` (+ RLM Billing `BillingSchedule`→`Invoice`). On activation, create/link a `MaintenancePlan` (+ `ServiceContract` for the entitlement layer) to deliver visits.
3. **Order/Contract + scheduled billing** (lightweight): standard `Contract`/`Order` + a Flow/Apex for charges; `MaintenancePlan` delivers. No extra license.

**Roles:** `ServiceContract` = commercial coverage terms; `Entitlement` = what service is owed (work type/SLA/window); `ContractLineItem.AssetId` = asset-based coverage; `MaintenancePlan.ServiceContractId` = recurring visits fulfill the contract.

## End-to-end flow (step → object → owning cloud)
| # | Step | Object(s) | Cloud |
|---|---|---|---|
| 1 | Quote (subscription/maintenance SKU) | `Quote`,`QuoteLineItem`(`ProductSellingModelId`) | RLM |
| 2 | Convert to order | `Order`,`OrderItem` | RLM |
| 3 | Activate → provision | `Asset`+`AssetStatePeriod`(New)+`AssetAction`+`AssetActionSource`→OrderItem | RLM |
| 4 | Attach coverage | `ServiceContract`,`ContractLineItem`(`AssetId`),`Entitlement`,`AssetContractRelationship` | bridge |
| 5 | Stand up schedule | `MaintenancePlan`(`ServiceContractId`),`MaintenanceAsset`(`AssetId`),`MaintenanceWorkRule`(RRULE) | FSL |
| 6 | Generate work | `WorkOrder`(+`WorkOrderLineItem`),`ServiceAppointment` | FSL |
| 7 | Schedule/dispatch | `AssignedResource`; SA times set | FSL |
| 8 | Complete visit | SA `Completed`,`ServiceReport`(+`DigitalSignature`),`ProductConsumed` | FSL |
| 9 | Usage feedback (opt) | usage/`RateCardEntry`/`TransactionJournal` | FSL→RLM |
| 10 | Renew/amend/cancel | new `AssetStatePeriod`+`AssetAction` (or period end) | RLM |
| 11 | Extend coverage | `ServiceContract`/`Entitlement` dates + `MaintenancePlan.EndDate` → next WO batch | bridge→FSL |

## Renewal coupling — ⚠️ this is CUSTOM (not automatic)
Renewing/amending an RLM Asset does **not** auto-extend the `MaintenancePlan`/`ServiceContract`. Build a Flow/Apex trigger on `AssetAction.Category` (or new `AssetStatePeriod`):
| RLM event | ServiceContract/Entitlement | MaintenancePlan |
|---|---|---|
| Renew | extend `EndDate`s | extend `EndDate`; regenerate WOs for new term |
| Amend up | raise CLI qty/coverage | add `MaintenanceAsset` rows; regenerate upcoming WOs |
| Amend down | reduce CLI | remove/disable `MaintenanceAsset`; cancel future unstarted WOs |
| Cancel | end contract/entitlement | `DoesAutoGenerateWorkOrders=false`+set `EndDate`; cancel future unscheduled SAs |

### Reference implementation (built & proven)
An **`after update` trigger on `Asset`** that walks `Asset → MaintenanceAsset → MaintenancePlan → (ServiceContractId) → ServiceContract` and keeps coverage in lockstep. Key off **Asset field changes** so it fires for both the Asset-direct agent path AND the engine path (add `AssetAction.Category` detection once Place Quote is provisioned):
- **RENEW** = `UsageEndDate` extended (`new > old`, not cancelled) → `MaintenancePlan.EndDate` and `ServiceContract.EndDate` = the Asset's new end date.
- **CANCEL** = `Status`→`Obsolete` → `MaintenancePlan.EndDate=today`, `DoesAutoGenerateWorkOrders=false`, `ServiceContract.EndDate=today`, and `Database.update(futureSAs,false)` to cancel `ServiceAppointment`s (Status NOT IN Completed/Canceled/Cannot Complete, `SchedStartTime>=now` or null) whose `ParentRecordId` is a `WorkOrder` with `MaintenancePlanId` in the cancelled plans.
Bulk-safe (collect ids → one query + one DML per object); no Asset recursion (writes Plan/SC/SA, not Asset). Proven live: asset renew pushed the new end date onto both MP+SC; asset cancel ended both today + stopped auto-gen.

### FSL gotchas hit building this (hard-won)
- **You cannot hand-insert a `MaintenanceAsset` against a hand-built plan** — the FSL managed-package trigger recomputes `NextSuggestedMaintenanceDate` and rejects the insert (`REQUIRED_FIELD_MISSING: [NextSuggestedMaintenanceDate]`) even when you set it, and even with a plan-level `MaintenanceWorkRule` + generation methods + `WorkType`. Maintenance Assets are reliably created only via Guided Setup / the plan's generation flow. **Test coupling against a chain the package built, not a synthetic one.**
- **`MaintenancePlan` insert needs a sane `GenerationTimeframe`** (`<= 20 years`) + `GenerationTimeframeType` — the default is out-of-range and the insert fails.
- **Prove cross-object triggers non-destructively with `Database.setSavepoint()` + `Database.rollback(sp)`** — drive renew/cancel on a REAL covered asset inside a savepoint, `System.debug` the post-trigger `MaintenancePlan`/`ServiceContract` values (queryable in-transaction after the trigger's DML), then roll back so the live FSL demo is untouched.

## Gotchas
1. No `Subscription` object — it's `Asset`+`AssetStatePeriod`+`AssetAction`+recurring `ProductSellingModel`.
2. **`MaintenancePlan.ServiceContractId` is hidden unless Entitlement Management is on** — the single field tying sold contract → recurring visits.
3. `Frequency`/`FrequencyType` retired (Oct 2025) → `MaintenanceWorkRule.RecurrencePattern` RRULE, parent `ParentMaintenancePlanId`.
4. `generateWorkOrders` = async, not DML, input `recordId`, blocked while auto-gen on; poll `WorkOrderGenerationStatus`.
5. Maintenance Plans only *create* work; SAs need the managed-package optimizer/Dispatcher Console to schedule (see `salesforce-field-service`).
6. FSL has no native invoice from a WorkOrder — formal billing = RLM Billing or ServiceContract + Pay Now/manual.
7. RLM↔FSL renewal coupling is custom Flow/Apex.

## Sources
- Asset Lifecycle / Asset / AssetStatePeriod / AssetActionSource / AssetContractRelationship — Revenue Cloud Developer Guide (`.../revenue_lifecycle_management_dev_guide/...`)
- Manage Asset Lifecycle / Contracts in Revenue Cloud — help.salesforce.com (`ind.qocal_asset_lifecycle`, `ind.qocal_manage_contracts_in_revenue_lifecycle_management`)
- Field Service Preventive Maintenance Data Model / `MaintenancePlan` — Field Service Developer Guide; Set Up Maintenance Plans (`service.fs_create_maintenance`)
- Data Model Gallery — Revenue Management: https://developer.salesforce.com/docs/platform/data-models/guide/revenue-cloud-category.html
