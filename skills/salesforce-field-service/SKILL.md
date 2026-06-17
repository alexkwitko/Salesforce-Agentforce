---
name: salesforce-field-service
description: Use when enabling, configuring, or troubleshooting Salesforce Field Service (a.k.a. Agentforce Field Service and Operations / FSL) — the org-pref enablement (FieldServiceSettings), installing the Field Service MANAGED PACKAGE (Dispatcher Console + scheduling optimizer + Guided Setup), Guided Setup, permission set licenses + permission sets, service territories/operating hours/resources/skills/crews, work orders → work order line items → service appointments, work types, scheduling policies + work rules + service objectives + the optimizer, the Dispatcher Console (Gantt/map) + Map Polygons, Order→WorkOrder→appointment conversion, custom auto-scheduling without the managed package, the mobile app, Appointment Assistant, Maintenance Plans (preventive/recurring work-order generation) and selling maintenance as a subscription (Service Contracts / Revenue Cloud), technicians accepting/managing payments in the field (Pay Now links, CommercePayments, card readers), Service Reports + digital signatures (job closeout), **embedding custom LWC + AI in the mobile app** (offline-aware quick actions, `lightning/mobileCapabilities` barcode/NFC/scanner, a DIY AI pre-visit-brief/draft-notes helper via `ConnectApi.EinsteinLLM` vs the native Agentforce for Field Service add-on), and the **RLM / Revenue Cloud ↔ Maintenance Plans ↔ Asset install-base** integration (sell→provision Asset→ServiceContract→recurring visits→renew), and the full data model. DX/CLI-first with exact metadata/API/Apex shapes, the official install hub, and hard-won gotchas.
---

# Salesforce Field Service (Agentforce Field Service and Operations) — Setup Playbook

Practical, **DX-first** playbook for standing up Salesforce Field Service end to end — the platform feature, the **managed package** (Dispatcher Console + optimizer), and the operational config. "Field Service Lightning (FSL)" → "Salesforce Field Service" → now branded **Agentforce Field Service and Operations**; same product, same objects, managed-package namespace is still **`FSL`**.

## The 3 layers (internalize this first)
1. **Core feature + standard objects** — `WorkOrder`, `ServiceAppointment`, `ServiceResource`, `ServiceTerritory`, etc. Turned on by an **org preference** (`FieldServiceSettings`). You can build custom auto-scheduling on this layer **without the managed package**.
2. **The Field Service MANAGED PACKAGE** (`FSL` namespace) — adds the **Dispatcher Console** (Gantt/map), the **scheduling optimizer**, **Guided Setup**, and the `FSL__*` scheduling objects (policies, work rules, service objectives). This is what most people mean by "Field Service." **Installing it is a separate step.**
3. **Separately-licensed add-ons** — **Appointment Assistant** (`FSA` package, real-time customer tracking), **Visual Remote Assistant** (video), **Workforce Engagement** (shift forecasting), **Salesforce Scheduler**, **Agentforce for Field Service** (AI in the mobile app). NOT part of base FSL.

> **The mistake to avoid:** enabling the org pref and thinking Field Service is "set up." The **app, Dispatcher Console, and optimizer come from the managed package** (layer 2). "Objects exist" ≠ "feature enabled" ≠ "managed package installed."

## #1 rule: DX/CLI/API first, UI last
`sf project deploy/retrieve`, `sf data`, `sf apex run`, `sf api request rest`. For Setup-UI-only steps, drive the org UI headlessly with `sf org open --path "<lightning path>" --url-only` (frontdoor auto-auths with the CLI token — no password). `sf org display` redacts the access token → prefer `sf api request rest` / Apex session over raw curl.

## Reference files (load as needed)
- **[setup-basics.md](setup-basics.md)** — enable the feature, install the managed package, **Guided Setup**, workforce (resources/crews/skills), territories/operating hours, work orders/WOLI/SA/work types, maintenance plans, inventory.
- **[scheduling-optimization.md](scheduling-optimization.md)** — scheduling policies, work rules, service objectives, the optimizer (global/in-day/RSO), appointment booking + arrival windows, scheduling recipes, the `FSL` Apex API.
- **[dispatcher-console-permissions.md](dispatcher-console-permissions.md)** — the Dispatcher Console (Gantt/map/list), permission set **licenses**, the FSL permission sets, exact assignment order/commands, making a dispatcher vs a technician end to end.
- **[mobile-and-extend.md](mobile-and-extend.md)** — the Field Service mobile app (offline/briefcase/push), Appointment Assistant (FSA), Visual Remote Assistant, Workforce Engagement, Agentforce for Field Service.
- **[maintenance-payments-reports.md](maintenance-payments-reports.md)** — Maintenance Plans (preventive/recurring WO generation) + selling them as a subscription (Service Contracts / Revenue Cloud), technicians accepting payments (Pay Now links, `CommercePayments`, partner card readers — what's native vs not), and Service Reports + digital signatures (templates, `createServiceReport` action, `DigitalSignature`). Org-verified field names.
- **[data-model-reference.md](data-model-reference.md)** — every object, key fields, relationships, the FSL custom objects, the compact relationship map.

---

## Quick start (the happy path)

### 1. Enable the core feature (metadata)
Deploy `FieldServiceSettings` (the **real** field names — `enableFieldService` does NOT exist):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<FieldServiceSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <fieldServiceOrgPref>true</fieldServiceOrgPref>
    <enableWorkOrders>true</enableWorkOrders>
</FieldServiceSettings>
```
(Scratch org alternative: feature `FieldServiceLightning` + the same settings in `project-scratch-def.json`.) Verify `WorkOrder`/`ServiceAppointment` are usable.

### 2. Install the managed package (the part that's easy to skip)
The package delivers the Dispatcher Console + optimizer + Guided Setup. **Install path — official, version-safe:**
- Salesforce's own install hub: **`https://fsl.secure.force.com/install`** (a.k.a. the "Field Service Package Installation Hub"). Click **Install in Production** (Dev Edition = production-type) → reveals the current package version id in the install URL (`installPackage.apexp?p0=04t…`).
- Then install headlessly via CLI: `sf package install --package <04t…> -o <org> -w 30 -r --security-type AdminsOnly`.
- **The same hub lists "Appointment Assistant" and "Field Service Starter Kit"** — each with its own `04t`.
- ⚠️ **Security note (agent context):** a Claude Code auto-mode classifier **blocks installing a managed package whose `04t` the agent discovered** (it's external code entering the org). The user must **name/confirm the `04t`** (then it's user-authorized) or run `sf package install` themselves. The `04t` changes every release — get the current one from the hub, don't hardcode. Verify install: `sf package installed list` shows the `FSL` namespace.

### 3. Run Guided Setup (creates the permission sets + default scheduling config)
After the package installs, **FSL permission sets = 0 and there are no default scheduling policies until Guided Setup runs.** Open **App Launcher → Field Service Admin → Field Service Settings tab → "Go to Guided Setup"** (drive headlessly via the frontdoor). Guided Setup:
- **Creates the FSL permission sets** from package templates (Admin/Agent/Dispatcher/Resource — UI-only, click "Create Permissions" per tile; re-run "Update" after each package upgrade).
- Creates the **default scheduling policies** (Customer First, High Intensity, Soft Boundaries, Emergency), standard **work rules**, and **service objectives**.
- Installs the scheduling **triggers** + sharing.
- Lets you bulk-create **Service Resources** from users.
See [dispatcher-console-permissions.md](dispatcher-console-permissions.md) and [scheduling-optimization.md](scheduling-optimization.md).

### 4. Make a dispatcher / technician (API-doable; PSL BEFORE perm set)
```apex
// 1) PSL first (perm-set assignment fails without it)
insert new PermissionSetLicenseAssign(AssigneeId=uid,
   PermissionSetLicenseId=[SELECT Id FROM PermissionSetLicense WHERE DeveloperName='FSL_Dispatcher_License' LIMIT 1].Id);
// 2) then the FSL permission set (query the real Name; FSL namespace)
insert new PermissionSetAssignment(AssigneeId=uid,
   PermissionSetId=[SELECT Id FROM PermissionSet WHERE Name LIKE '%Dispatcher%' AND NamespacePrefix='FSL' LIMIT 1].Id);
```
- **Dispatcher** = Field Service Standard + **Field Service Dispatcher** PSL + FSL Dispatcher Permissions + a `ServiceTerritoryMember` with role Dispatcher on each territory they manage. The **Field Service tab won't render** without both the Dispatcher PSL and the perm set.
- **Technician** = Field Service Standard + **Field Service Scheduling** + **Field Service Mobile** PSLs + **`FSL_Resource_License` perm set (grants the `PermissionsFieldServiceScheduling` user permission — REQUIRED to be a scheduling candidate; the Scheduling PSL/license ALONE is not enough)** + FSL Resource Permissions + `FieldServiceMobileStandardPermSet` + a `ServiceResource` (`ResourceType='T'`, `IsActive=true`) + primary `ServiceTerritoryMember` + skills. ⚠️ Miss the `FSL_Resource_License` perm set and the optimizer **silently never assigns** that resource (error: "Only users with the Field Service Scheduling user permission can be included in scheduling optimization"); a System-Admin resource hides this because the Admin profile already grants the permission. See dispatcher-console-permissions.md §"#1 reason a resource is never auto-assigned".
- PSL `DeveloperName`s and perm-set `Name`s vary by org/version — **query them** (`PermissionSetLicense`, `PermissionSet WHERE NamespacePrefix='FSL'`), don't hardcode.

### 5. Seed the operational data (all API-doable, no UI)
Order matters: `OperatingHours` (+`TimeSlot`) → `ServiceTerritory` → `Skill` → `ServiceResource` (+`ServiceResourceSkill`, `ServiceTerritoryMember` **primary**) → `WorkType`. Scheduling/optimization only runs for territories that have **at least one primary** member.

### 6. Order → Field Service (custom, no managed package needed)
`OrderToFieldService` Apex (callable from a record-triggered Flow / storefront / Agentforce action):
- Query OrderItems where `Product2.Requires_Field_Service__c = true`; idempotent on `WorkOrder.Source_Order_Id__c`.
- Create `WorkOrder` (AccountId, default `ServiceTerritoryId`, `Pricebook2Id` from Order) → `WorkOrderLineItem` per serviceable line (set `PricebookEntryId`+`Product2Id`; try/catch fallback drops product+pricebookentry+quantity, Description-only) → unscheduled `ServiceAppointment` (`Status='None'`, `ParentRecordId=WO`).
- **Auto-schedule without the package**: a Queueable that picks a slot and sets `SchedStartTime`/`SchedEndTime`/`Status='Scheduled'` + inserts `AssignedResource`. **With** the package, call the optimizer instead (`FSL.ScheduleService.schedule(policyId, saId)` / `FSL.OAAS`).

---

## Top gotchas (full lists in the reference files)
- **3 layers**: org pref ≠ managed package ≠ add-ons. The Dispatcher Console/optimizer/Guided Setup need the **managed package**.
- `enableFieldService` is invalid → `fieldServiceOrgPref` + `enableWorkOrders`. Work Orders can be on without Field Service; once FS is on you can't turn WOs off.
- **Managed package install**: get the current `04t` from `fsl.secure.force.com/install`; the agent-discovered id is blocked unless the user names it; **approve third-party access** at install or the optimizer/geocoding silently break.
- **Guided Setup permission-set creation is UI-only** (click the tiles); the assignments (`PermissionSetLicenseAssign` → `PermissionSetAssignment`) are API-doable. **PSL before perm set.**
- **Scheduling needs a PRIMARY `ServiceTerritoryMember`**; a resource has only one primary; **Relocation** overrides primary during its dates.
- **Every scheduling policy needs a Service Resource Availability work rule** or absences/breaks are ignored. **Clone the default policies, never edit them in place.**
- **`ServiceAppointment.Status='None'` = unscheduled; `ParentRecordId` is polymorphic and immutable** after create.
- WOLI `Product2Id` needs WO.`Pricebook2Id` + WOLI.`PricebookEntryId` (v52+ auto-fills Product2Id).
- `ServiceResource` can't be deleted (deactivate); can't link to an inactive user.
- **Optimization is async** — poll `FSL__Optimization_Request__c`; the running/background user needs the optimization perms ("Not Authorized" otherwise).
- Mobile worker needs BOTH the **Mobile** and **Scheduling** PSLs; share the worker their own `ServiceResource` record; the connected app is mandatory for push + briefcase.
- **"You must have Dispatcher license" loading the console** = the console checks the **`FSL_Dispatcher_Permissions` + `FSL_Dispatcher_License` PERM SETS**, not just the Dispatcher PSL. Assign both (PSL first) → Gantt loads. (Package post-install auto-creates the `FSL_*` perm sets + the 4 default scheduling policies / 14 work rules / 10 objectives.)
- **Two consoles**: Classic Dispatch Console (Aura/VF Gantt, works out of the box) vs the new **Scheduling Console** (LWC) which **requires ES&O** (`o2EngineEnabled` — a significant ~one-way engine migration). ⚠️ **Setting `o2EngineEnabled` via the Metadata API is necessary-but-NOT-sufficient** — it makes the tab appear but does NOT provision the O2/OIS optimization service (the Setup-UI "Enhanced Scheduling and Optimization → Enable" button does that side-effecting registration). Symptom of flag-on-but-not-provisioned: `schedule()` throws "Schedule optimization incomplete", new console "couldn't load availability", `FSL__O2_Settings__mdt`=0 records, `FSL__Optimization_Request__c`=0 ever. See dispatcher-console-permissions.md §0.
- **Empty dispatcher map** = territories aren't geocoded. Set `ServiceTerritory` `StateCode`/`CountryCode` (NOT State/Country text — picklist orgs throw FIELD_INTEGRITY) + `Latitude`/`Longitude` (directly writable) + resource `LastKnownLatitude/Longitude`. Boundary polygons (`FSL__Polygon__c`) **CAN be created via Apex/API DML** (verified) — the gotcha is `FSL__KML__c` coordinates must be **NEWLINE-separated, not space-separated** (space-sep → managed-trigger error `Polygon KML data structure is invalid: []`). Use OGC namespace + full `<kml>…<coordinates>` wrapper, one `lon,lat,0` per line; set `FSL__Color__c` (#hex) + `FSL__Service_Territory__c`; the trigger computes the bounding box on insert. UI paths (Map draw / Map Polygons New with KML Details / Import KML) also work — but the default Map Polygon layout is stripped (Name/Owner only; add the fields), the tab's "Import" button is just the CSV Data Import Wizard (not a KML file upload), and the dispatch-console map is a cross-origin Google-Maps iframe whose layer/zoom controls only respond to a real mouse (not automation). They drive the geofence → territory assignment (`FSL.PolygonUtils`). See dispatcher-console-permissions.md.
- **Managed-package layout retrieve gotcha:** `sf org list metadata -m Layout` reports a managed layout as `Object-Label` (e.g. `FSL__Polygon__c-Polygon Layout`), but that name fails to retrieve/deploy. The real API name doubles the namespace onto the label: `Object-NS__Label` (e.g. `FSL__Polygon__c-FSL__Polygon Layout`). Subscribers CAN add fields to a managed layout + redeploy it.
