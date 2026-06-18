# Field Service — Object & Relationship Reference

Standard Field Service objects (available once the feature is enabled) + the **FSL managed-package** custom objects (`FSL` namespace, installed separately). API versions = minimum availability. Basic WO/WOLI/SA create+schedule does NOT need the managed package — only the optimizer/console do.

## Work objects
**WorkOrder** (v36+): `AccountId`, `ContactId`, `AssetId`, `CaseId`, `EntitlementId`/`ServiceContractId`, `WorkTypeId`, `ServiceTerritoryId`, `LocationId`, **`Pricebook2Id`** (req so WOLIs carry a product), `ParentWorkOrderId`/`RootWorkOrderId`, `Status`/`StatusCategory`, `Priority`, `Duration`/`DurationType`, `StartDate`/`EndDate`, compound `Address`, rollups (`Subtotal`/`TotalPrice`/`GrandTotal`).

**WorkOrderLineItem** (v36+): `WorkOrderId` (master-detail), `ParentWorkOrderLineItemId`/`Root…`, **`PricebookEntryId`** (set to carry a product), **`Product2Id`** (v52+ read-only, auto-from PricebookEntryId; older: set manually), `Quantity`/`UnitPrice`/`Subtotal`, `AssetId`, `WorkTypeId`, `Status`, `Duration`.
> **Product-link chain:** to put `Product2Id` on a WOLI, the parent WO needs `Pricebook2Id` AND the WOLI needs a `PricebookEntryId` from that pricebook. If rejected, drop Product2Id+PricebookEntryId+Quantity (Description-only).

## Service appointment & scheduling
**ServiceAppointment** (v38+): **`ParentRecordId`** polymorphic → WorkOrder/WOLI/Asset/Account/Opportunity/Lead (+ `ParentRecordType`/`ParentRecordStatusCategory`); **immutable** after create. `Status` mapped to categories: **`None`=unscheduled** → Scheduled → Dispatched → In Progress → Cannot Complete/Completed/Canceled (custom statuses map to a category). `EarliestStartTime`+`DueDate` (window), `ArrivalWindowStartTime`/`EndTime` (customer promise), `SchedStartTime`/`SchedEndTime` (booked slot), `ActualStartTime`/`EndTime`/`ActualDuration`, `Duration`/`DurationType`, `ServiceTerritoryId`, `ContactId`, `AppointmentNumber` (autonum), `ServiceNote`, address. **Schedule** = set SchedStart/End + Status='Scheduled' + insert AssignedResource.

**AssignedResource** (v38+): `ServiceAppointmentId` (master-detail), `ServiceResourceId`, `ServiceCrewId` (optional). Multiple = multi-resource appointment.

## Workforce
**ServiceResource** (v38+): `RelatedRecordId`→User (when Technician), `AccountId` (contractor/dispatcher), **`ResourceType`** (`T` Technician / `D` Dispatcher / `C` Crew / `S` Asset / `A` Agent / `P` Planner), `IsActive`, `IsCapacityBased`. Can't delete; can't link to inactive user.
**ServiceResourceSkill** (v38+): `ServiceResourceId` (master-detail), `SkillId`, `SkillLevel` (0–99.99), `EffectiveStartDate`/`EndDate`.
**ServiceCrew** (v40+) / **ServiceCrewMember** (v40+): `ServiceCrewId` (master-detail), `ServiceResourceId`, `StartDate`/`EndDate`, `IsLeader`.
**Skill** (Setup) / **SkillRequirement**: on WorkType/WO/WOLI (`RelatedRecordId`, `SkillId`, `SkillLevel`); matched vs ServiceResourceSkill.
**ResourceAbsence** (v38+): `ResourceId`, `Type`, `Start`, `End`, `ServiceTerritoryId`.

## Territories & hours
**ServiceTerritory** (v38+): `OperatingHoursId` (req for scheduling), `ParentTerritoryId` (hierarchy), `IsActive`, `Address`. (~50 resources/territory, ~1,000 appts/day guidance.)
**ServiceTerritoryMember** (v38+): `ServiceResourceId` (master-detail), `ServiceTerritoryId`, `EffectiveStartDate`/`EndDate` (req for Relocation), **`TerritoryType`** Primary (one) / Secondary (many) / Relocation (temporary, overrides primary during dates), member `OperatingHoursId` override.
**ServiceTerritoryLocation** (v40+): territory ↔ Location.
**OperatingHours** (v38+): `Name`, `TimeZone`. **TimeSlot** (v38+): `OperatingHoursId` (master-detail), `DayOfWeek`, `StartTime`, `EndTime`, `Type`, optional `WorkTypeGroupId`.

## Templates
**WorkType** (v38+): `EstimatedDuration`, `DurationType`, `ShouldAutoCreateSvcAppt`, `BlockTimeBefore/After`, `MinimumCrewSize`/`RecommendedCrewSize`, `OperatingHoursId`; skills via SkillRequirement.
**WorkTypeGroup** (v45+) + **WorkTypeGroupMember**: group work types for appointment booking/self-scheduling; surfaced via `TimeSlot.WorkTypeGroupId`.

## Maintenance & campaigns
**MaintenancePlan** (v50+): `AccountId`, `WorkTypeId`, `ServiceTerritoryId`, `StartDate`, `Frequency`/`FrequencyType`, `GenerationTimeframe`, `WorkOrderGenerationMethod`, `NextSuggestedMaintenanceDate`.
**MaintenanceAsset** (v50+): `MaintenancePlanId` (master-detail), `AssetId`, `WorkTypeId`, `MaintenanceWorkRuleId`.
**MaintenanceWorkRule** (v49+): `RecurrencePattern` (RRULE).
**ProductServiceCampaign** (v51+) + **ProductServiceCampaignItem**: recall/upgrade/inspection across assets.

## Service documentation
**ServiceReport** (v41+): polymorphic `ParentId` → WO/WOLI/SA, `DocumentId`, `ServiceReportLayoutId`. **ServiceReportLayout** (Setup) — template.

## Inventory
**ProductItem** (`Product2Id`, `LocationId` master-detail, `QuantityOnHand`), **ProductItemTransaction**, **ProductRequest** + **ProductRequestLineItem**, **ProductTransfer** (`Source/DestinationLocationId`, `QuantitySent/Received`), **ProductConsumed** (`WorkOrderId`/`WorkOrderLineItemId`, `ProductItemId`, `QuantityConsumed`), **ReturnOrder** + **ReturnOrderLineItem**, **Location** (`LocationType`, `IsInventoryLocation`, `IsMobile`, `ParentLocationId`), **Address**.

## FSL managed-package custom objects (`FSL` namespace)
| Object | What it is |
|---|---|
| `FSL__Scheduling_Policy__c` | The who/when/where rulebook (work rules + objectives). ~4 defaults. |
| `FSL__Work_Rule__c` | Hard constraint/filter (eligibility). |
| `FSL__Service_Goal__c` | Soft objective / scoring weight. |
| `FSL__Scheduling_Policy_Work_Rule__c` | Junction policy ↔ work rules. |
| `FSL__Scheduling_Policy_Goal__c` | Junction policy ↔ goals, **carries `Weight`**. |
| `FSL__Optimization_Request__c` | A queued/global optimization run (status/scope/horizon). |
| `FSL__Time_Dependency__c` | Scheduling dependency between appointments (same day / immediately after / same resource). |
| `FSL__Polygon__c` | Map polygon for geofence → territory assignment (`FSL.PolygonUtils` lat/long→territory). **Apex/API DML WORKS** — but `FSL__KML__c` coords must be **newline-separated** (not space-separated) OGC KML; managed trigger computes the bbox on insert. UI (Map draw / KML import) also works. |
| `FSL__Logged_Dependency__c` | Diagnostics log of time-dependency evaluation. |

Wiring:
```
FSL__Scheduling_Policy__c
   ├──< FSL__Scheduling_Policy_Work_Rule__c >── FSL__Work_Rule__c     (hard: WHO is eligible)
   └──< FSL__Scheduling_Policy_Goal__c (Weight) >── FSL__Service_Goal__c  (soft: pick BEST)
FSL__Optimization_Request__c ── runs a policy across territories/time
FSL__Time_Dependency__c ──(logged via)── FSL__Logged_Dependency__c ;  FSL__Polygon__c ── geofence→territory
```

## Compact relationship map
```
Account ─┬─< WorkOrder ─┬─< WorkOrderLineItem (WO.Pricebook2Id + WOLI.PricebookEntryId → Product2Id)
         │              ├─< ServiceAppointment (ParentRecordId polymorphic → WO/WOLI/Asset/…)
         │              │        └─< AssignedResource ── ServiceResource ── User
         │              └── WorkType (template; SkillRequirement)
         ├── Contact / Asset / Case / Entitlement / ServiceContract
ServiceTerritory ── OperatingHours ──< TimeSlot (── WorkTypeGroup)
   │   └─< ServiceTerritoryMember (Primary/Secondary/Relocation) ── ServiceResource
   └─< ServiceTerritoryLocation ── Location ──< ProductItem ──< ProductItemTransaction
ServiceResource ─┬─< ServiceResourceSkill ── Skill
                 ├─< ResourceAbsence
                 └─< ServiceCrewMember ── ServiceCrew
MaintenancePlan ─< MaintenanceAsset ── Asset ;  ProductServiceCampaign ─< …Item ── Asset/WorkOrder
ServiceReport (ParentId: WO/WOLI/SA) + ServiceReportLayout
Inventory: ProductRequest ─< …LineItem ; ProductTransfer ; ProductConsumed ; ReturnOrder ─< …LineItem
```

## Feature gates
Standard objects need Field Service enabled; `FSL__*`/optimization/polygon/Dispatcher Console need the **managed package**; maintenance/PSC/inventory need Field Service; appointment booking via WorkTypeGroup needs the booking/Scheduler features; mobile fields need Field Service Mobile.

Sources: Field Service Developer Guide (`fsl_dev_soap_core.htm`, `fsl_dev_soap_objects.htm`), object reference pages, `service.fs_appointment_fields.htm`. (Dev-guide pages are JS-rendered; verify exact min-API-versions/field casing against the org's describe before coding.)
