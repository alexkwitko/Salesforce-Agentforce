# Field Service — Setup Basics

Enable the feature, install the managed package, run Guided Setup, build the workforce + territories, and create work. Sourced from the Field Service Developer Guide, the `FieldServiceSettings` Metadata API reference, help.salesforce.com (`service.pfs_*` / `service.fs_*`), and Trailhead.

## 1. Enable Field Service (the org preference)
Two layers: (a) core feature/standard objects via an org pref; (b) the optional **managed package** (§2). `FieldServiceSettings` is a Settings metadata type — deploy via `sf project deploy` (`force-app/main/default/settings/FieldService.settings-meta.xml`, root element `FieldServiceSettings`).

Key fields (boolean unless noted):
| Field API name | Enables |
|---|---|
| **`fieldServiceOrgPref`** | Master switch — Field Service enabled. Set `true`. |
| **`enableWorkOrders`** | WorkOrder object (can be on without Field Service; once FS is on you can't turn WOs off). |
| `fieldServiceNotificationsOrgPref` | In-app/mobile notifications on WO/WOLI changes. |
| `o2EngineEnabled` | **Enhanced Scheduling & Optimization (ES&O)** — newer in-platform engine (API v55+). Different code path from the classic managed-package optimizer; pick one deliberately. |
| `enableWorkPlansAutoGeneration` | Auto-generate Work Plans/Steps per selection rules (v52+). |
| `doesShareSaWithAr` / `doesShareSaParentWoWithAr` | Share dispatched SAs / their parent WO with assigned resources. |
| `isGeoCodeSyncEnabled` / `isLocationHistoryEnabled` | Sync ServiceResource location / track location history. |
| `enableDocumentBuilder`, `enableStandbyMode`, `mobileFeedbackEmails`, … | Document Builder, mobile standby, feedback email, etc. |

Minimal enable XML is in SKILL.md §1. Scratch org: `"features": ["FieldServiceLightning"]` + `"settings": { "fieldServiceSettings": { "fieldServiceOrgPref": true, "enableWorkOrders": true } }`. Help: `service.pfs_get_started.htm`; metadata ref `meta_fieldservicesettings.htm`.

## 2. Install the Field Service MANAGED PACKAGE (`FSL` namespace)
The org pref gives the data model; the **managed package** adds Guided Setup, the Dispatcher Console (Gantt + map + appointment list), the scheduling/optimization engine, the Field Service Admin app, and `FSL.`-namespaced objects/config.

Steps:
1. Enable Field Service first (§1) — the package depends on it.
2. Open Salesforce's official **install hub**: `https://fsl.secure.force.com/install` (the "Field Service Package Installation Hub"; shows the current release, e.g. "Summer '26"). Click **Install in Production** / **Install in Sandbox**. The button's URL exposes the current `installPackage.apexp?p0=04t…` version id.
3. CLI install (headless): `sf package install --package <04t…> -o <org> -w 30 -r --security-type AdminsOnly`. Or click through the hub install page (Install for Admins Only).
4. **Approve third-party access** for the geocoding/optimization endpoints — REQUIRED; skipping it silently breaks optimization.
5. Verify: `sf package installed list` shows `FSL`. The package's custom objects (`FSL__Scheduling_Policy__c`, `FSL__Work_Rule__c`, `FSL__Service_Goal__c`, `FSL__Optimization_Request__c`) become present immediately, but **FSL permission sets and default scheduling policies are 0 until Guided Setup runs** (§3).

Help: `service.pfs_install.htm`.

## 3. GUIDED SETUP
**Field Service Admin app → Field Service Settings tab → "Go to Guided Setup."** A managed-package wizard (largely **UI-only**) that bootstraps operational config. Steps:
1. **Create Permission Sets** — generates the FSL role permission sets from package templates (Field Service Admin / Dispatcher / Agent / Resource / Scheduling). Click "Create Permissions" per tile; re-run "Update" after each package upgrade. Then assign (Setup → Permission Sets → Manage Assignments) — and the matching PSL (see dispatcher-console-permissions.md).
2. **Create Service Resources** — bulk-turn active users into `ServiceResource` records.
3. **Define scheduling rules/policies** — creates the default **Scheduling Policies** (Customer First, High Intensity, Soft Boundaries, Emergency), standard **Work Rules**, and **Service Objectives**.
4. **Create scheduling/optimization triggers & sharing** — installs/activates the managed-package Apex triggers and configures resource sharing (the `doesShareSaWithAr` / `doesShareSaParentWoWithAr` settings).
5. **Configure appointment booking / Field Service Settings** — operating hours defaults, scheduling/optimization horizon, arrival-window behavior, the optimization (running) user.
6. **(Optional) Enable Optimization** — register the org for the optimizer, set the optimization user + a recurring schedule.

The resulting policies/rules/objectives are FSL custom objects — queryable/editable via API afterward, but the supported authoring path is Guided Setup. Help: `service.pfs_get_started.htm`, `service.pfs_scheduling.htm`.

## 4. Building the workforce
- **`ServiceResource`** (v38+) — a technician/crew/asset. `Name` (req), `RelatedRecordId`→User (blank for crews), **`ResourceType`** restricted picklist (`T` Technician default, `D` Dispatcher, `C` Crew, `S` Asset, `A` Agent, `P` Planner — dispatchers can't be capacity-based/optimized and need the Dispatcher PSL), `IsActive`, `IsCapacityBased` (+ child `ServiceResourceCapacity`), `LocationId` (van). **Can't be deleted (deactivate); can't link to an inactive user; deactivating the user doesn't deactivate the resource.** `IsOptimizationCapable` is reserved — use a custom field instead.
- **`ServiceCrew`** + **`ServiceCrewMember`** — a crew group; create a `ResourceType=C` ServiceResource whose `ServiceCrewId` points to the crew (that's how the crew schedules).
- **`Skill`** (Setup → Skills) + **`ServiceResourceSkill`** (`SkillId`, `ServiceResourceId`, `SkillLevel` 0–99.99, `EffectiveStartDate`/`EndDate`).
- **`ResourceAbsence`** — unavailable periods (PTO, lunch, training).
- **`ResourcePreference`** — an account's Preferred/Required/Excluded resource (drives the Preferred Resource objective + Required Resource work rule).

## 5. Territories, Operating Hours, Time Slots
- **`ServiceTerritory`** (v38+) — region. `OperatingHoursId`, `ParentTerritoryId` (multilevel hierarchy Country→State→City), `IsActive`, `Address`.
- **`ServiceTerritoryMember`** — assigns a resource to a territory. **`TerritoryType`**: **Primary** (one per resource; **scheduling only runs for territories with ≥1 primary member**), **Secondary** (many), **Relocation** (temporary; overrides primary during its dates). Plus `EffectiveStartDate`/`EndDate`, member-level `OperatingHoursId` override.
- **`OperatingHours`** + **`TimeSlot`** — reusable schedules; one TimeSlot per day with `StartTime`/`EndTime`. Members inherit territory hours unless given their own. **By default only System Admins can view/create OperatingHours** — grant access explicitly.

## 6. Work Orders, WOLI, Service Appointments, Work Types
- **`WorkType`** (v38+) — job template: `EstimatedDuration` + `DurationType` (Minutes/Hours), `ShouldAutoCreateSvcAppt` (auto-creates the SA), child `SkillRequirement`s. Setting a WO's `WorkTypeId` inherits duration + skills.
- **`WorkOrder`** (v36+) — `AccountId`, `WorkTypeId`, `ServiceTerritoryId`, `Pricebook2Id` (needed so WOLIs carry a product), `Status`, `Priority`, `Duration`/`DurationType`.
- **`WorkOrderLineItem`** (v36+) — subtask; `PricebookEntryId` (+ `Product2Id`), `Quantity`, child SA/skills. Model multi-step jobs as parent WO + child WOLIs.
- **`ServiceAppointment`** (v38+) — the schedulable visit. `ParentRecordId` (polymorphic → WO/WOLI/Asset/Account; **immutable**), `EarliestStartPermitted`+`DueDate` (SLA window), `Duration`, `SchedStartTime`/`SchedEndTime` (set when booked), `ArrivalWindowStartTime`/`EndTime` (customer-facing), `Status` (**None=unscheduled** → Scheduled → Dispatched → In Progress → Completed/Cannot Complete/Canceled).
- **`AssignedResource`** — junction SA↔ServiceResource (created on scheduling).
- **`SkillRequirement`** — required skill+level on WorkType/WO/WOLI; matched against `ServiceResourceSkill` by the Match Skills work rule.
- **Serviceable-product pattern**: a `Product2.Requires_Field_Service__c` checkbox flags which order lines spawn work; associate WorkTypes with the products they service; `ProductRequired` (parts to bring), `ProductConsumed` (parts used), `Asset` (the installed product being serviced).

## 7. Maintenance plans, payments & Service Reports
- **`MaintenancePlan`** + **`MaintenanceAsset`** (+ `MaintenanceWorkRule` recurrence/RRULE) — preventive maintenance generating WOs on a schedule; the **`generateWorkOrders`** action (plural) is REST/Apex-callable (not DML; auto-generate must be off to call it manually). Generated WOs inherit duration/skills/products from the WorkType. ⚠️ `Frequency`/`FrequencyType` retired Oct 2025 — recurrence lives in `MaintenanceWorkRule.RecurrencePattern`.
- **`ServiceReport`** (+ `ServiceReportLayout` template — ⚠️ NOT in the `sf` metadata registry, so template design is Setup-UI-only) + **`DigitalSignature`** — customer-facing summary/sign-off generated via the **`createServiceReport`** action (not DML), signed in the mobile app.
- 👉 **Full detail** — Maintenance Plans + selling as a subscription, technician payments (Pay Now / CommercePayments / partner card readers), and Service Reports + signatures with org-verified field names: see **[maintenance-payments-reports.md](maintenance-payments-reports.md)**.

## 8. Inventory basics
- **`Location`** (warehouse / **service vehicle** / site; link a van to `ServiceResource.LocationId`), **`ProductItem`** (stock of a product at a location), **`ProductRequest`** / **`ProductRequestLineItem`** (order for parts), **`ProductTransfer`** (move stock between locations), **`ProductConsumed`** (parts used on a WO/WOLI).

## Gotchas
- Two switches: `fieldServiceOrgPref` (FS) + `enableWorkOrders` (WO can be on independently; can't turn WOs off once FS is on).
- **Org pref ≠ managed package** — Dispatcher Console/optimizer/Guided Setup/scheduling objects all come from the `FSL` package.
- **Approve third-party access during package install** or optimization/geocoding break silently.
- **Guided Setup is largely UI-only** — its FSL-namespaced output isn't cleanly metadata-deployable; provision via the wizard, then read/tweak via API.
- `ServiceResource` can't be deleted; can't link to an inactive user; `IsOptimizationCapable` reserved.
- `ResourceType` is a fixed picklist (`T/D/C/S/A/P`); dispatchers can't be capacity-based/optimized and need the Dispatcher PSL; dependent lookup filters use the first letter only.
- **Scheduling needs ≥1 primary `ServiceTerritoryMember`**; one primary per resource; Relocation overrides primary during its dates.
- OperatingHours visible to System Admins only by default; members inherit territory hours unless overridden.
- **WorkType is the inheritance hub** — null duration on the work type means scheduling has no length to plan.
- `ServiceAppointment.ParentRecordId` is immutable; `WorkType.ShouldAutoCreateSvcAppt=true` spawns the SA (don't also create one in code → duplicates).
- `SchedStartTime`/`SchedEndTime` set by the optimizer when assigned; without the package you set them yourself + insert `AssignedResource`. Capacity is advisory without the package.

Help slugs: `service.pfs_get_started.htm`, `service.pfs_install.htm`, `service.pfs_scheduling.htm`, `service.fs_territory_guidelines.htm`, `service.fs_create_work_types.htm`, `service.fs_create_maintenance.htm`, `service.fs_perm_set_licenses.htm`, `meta_fieldservicesettings.htm`.
