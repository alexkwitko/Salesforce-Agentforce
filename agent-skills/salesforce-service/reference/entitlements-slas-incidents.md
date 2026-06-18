# Entitlements / SLAs / Support Operations (DX reference)

> Cross-confirmed vs the Entitlements implementation guide, Data Model Gallery, v67 Metadata API PDF. Verify exact `CaseMilestone` field casing + CSIM junction FKs against the live Object Reference before coding inserts.

## 1. Entitlement Management (the SLA engine)
An `Entitlement` defines eligible support; an `EntitlementProcess` (SLA process) drives `MilestoneType` steps that materialize as `CaseMilestone` rows tracking target/violation against `BusinessHours`.

### Enable
`EntitlementSettings` (Settings family) — master toggle (`enableEntitlements`/`entitlementsEnabled` — verify casing). Deploy `-m "Settings:Entitlement"`; **confirm in Setup** (some orgs need the UI checkbox first).

### Build order & types
1. **`BusinessHours`** — *object, not source metadata*; create via `sf data create record -s BusinessHours` / Apex. `BusinessHoursSettings` (Settings) holds org defaults.
2. **`Holiday`** — object; `sf data create record -s Holiday` (junction `BusinessHoursHoliday`). Suspends the SLA clock.
3. **`MilestoneType`** (`milestoneTypes/<Name>.milestoneType-meta.xml`): `label`, `recurrenceType` (`NoRecurrence`/`Recurs`/`Independent`), `description`.
4. **`EntitlementProcess`** — the SLA process. **Dev-names are version-suffixed** (e.g. `MyProcess_v1`); use `versionMaster` for new versions, retrieve before edit. Fields: `name`, `isActive`, `entryStartDateField` (the Case datetime the clock starts from, e.g. `Case.CreatedDate`), `SObjectType`, `isVersionDefault`/`versionMaster`/`versionNumber`, `exitCriteriaFilterItems`/`exitCriteriaFormula`.
   - **`milestones`** (`EntitlementProcessMilestoneItem`): `milestoneName` (→ MilestoneType), `businessHours`, `minutesToComplete`, `minutesCustomClass` (Apex `Support.MilestoneTriggerTimeCalculator` for dynamic targets by priority/tier), `milestoneCriteriaFilterItems`, `successActions` (`WorkflowActionReference[]`), `timeTriggers`.
   - **`timeTriggers`** (`EntitlementProcessMilestoneTimeTrigger`): `timeLength`, `workflowTimeTriggerUnit` (`Minutes`/`Hours`/`Days`), `actions`. **Negative offset = warning (before target), positive = violation (after); success actions live at the milestone level.**
   - **`WorkflowActionReference`**: `name` + `type` (`FieldUpdate`/`Alert`/`FlowAction`/`Task`). **Modern best practice: wire a `FlowAction`**, not legacy Workflow Rules (EOL), though time-trigger actions still bind to this classic reference shape.
```xml
<EntitlementProcess xmlns="http://soap.sforce.com/2006/04/metadata">
  <active>true</active><businessHours>Default</businessHours>
  <entryStartDateField>Case.CreatedDate</entryStartDateField>
  <isVersionDefault>true</isVersionDefault><name>Standard Support SLA</name>
  <SObjectType>Case</SObjectType><versionNumber>1</versionNumber>
  <milestones>
    <milestoneName>First Response</milestoneName><minutesToComplete>60</minutesToComplete>
    <businessHours>Default</businessHours>
    <timeTriggers><timeLength>45</timeLength><workflowTimeTriggerUnit>Minutes</workflowTimeTriggerUnit>
      <actions><name>Warn_Owner_FR</name><type>Alert</type></actions></timeTriggers>
  </milestones>
</EntitlementProcess>
```
5. **`EntitlementTemplate`** — predefined terms on a `Product2`; auto-creates Entitlements when a matching Asset is created.

### How milestones attach at runtime (the part people miss)
Set **`Case.EntitlementId`** (lookup to `Entitlement`). The Entitlement points to the process via **`Entitlement.SlaProcessId`** (`SlaProcess` = the object face of EntitlementProcess). When the Case meets `entryStartDateField` + milestone criteria, Salesforce auto-creates `CaseMilestone` rows. **Defining the process is NOT enough — without an Entitlement on the Case, nothing fires.** Drive Entitlement assignment via an Entitlement Verification flow / Apex on case create. `Entitlement` can source from Account, Contact, Asset, or ServiceContract/ContractLineItem.

`CaseMilestone` (track/report): `CaseId`, `MilestoneTypeId`, `StartDate`, `TargetDate`, `CompletionDate`, `IsCompleted`, `IsViolated`, `TimeRemainingInMins`, `TimeSinceTargetInMins`, `ElapsedTimeInMins`, `IsStopped`/`StopTime` (verify casing). `BusinessHours`/`Holiday`/`Entitlement`/`CaseMilestone` are data/objects — not source metadata.

### Best practices / gotchas
- Pin every milestone + the process to explicit `BusinessHours` (don't rely on implicit case business hours).
- Version processes (`versionMaster`) rather than editing live ones; keep old versions for in-flight cases.
- Drive actions through Flow.
- **Common failure: EntitlementProcess + milestones active but 0 Entitlement records → SLAs track nothing.** Create a default Entitlement and stamp `Case.EntitlementId` on create.
- **⚠️ The `Case.EntitlementId` "No such column" trap = FLS, not provisioning (hard-won, root-caused).** After enabling Entitlement Management, `Case.EntitlementId` (+ `SlaStartDate`, `SlaExitDate`, `MilestoneStatus`) are real fields **but default to hidden field-level security even for System Administrator / the integration user** — and Salesforce surfaces an FLS-hidden field as **"No such column 'EntitlementId' on entity 'Case'"** in SOQL, omits it from `sf sobject describe`, and throws *"Invalid field EntitlementId for Case"* on Apex `c.put(...)`. So it looks exactly like the field doesn't exist (and an Apex stamp class **deploys clean but runs as a silent no-op**), when really you just lack FLS.
  - **Diagnose the split:** the field shows in **Object Manager** (Case → Fields & Relationships → "Entitlement Name") and in Tooling `FieldDefinition`, but runtime SOQL/describe/Apex say it's missing. That gap = FLS, not absence.
  - **Confirm + fix in one move:** deploy a permission set with `fieldPermissions` for `Case.EntitlementId` etc. **If the deploy succeeds, the field exists and FLS was the whole problem** — assign that perm set to the integration/agent user (`EinsteinServiceAgent`) + human service users and SOQL works immediately. (Proven: granting FLS made `SELECT EntitlementId FROM Case` and milestone instantiation work end-to-end.)
  ```xml
  <PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata"><label>Entitlement Field Access</label>
    <fieldPermissions><field>Case.EntitlementId</field><readable>true</readable><editable>true</editable></fieldPermissions>
    <fieldPermissions><field>Case.SlaStartDate</field><readable>true</readable><editable>true</editable></fieldPermissions>
  </PermissionSet>
  ```
  - **Only if the `fieldPermissions` deploy ERRORS "field not found"** is the field genuinely unprovisioned — then a UI **off→Save→on→Save** cycle in Setup → Entitlement Settings provisions it (entitlement/process records survive). Enabling purely via the `EntitlementSettings` metadata flag can set `enableEntitlements=true` without fully provisioning, so always verify with the FLS test.
  - The agent user that creates cases needs this FLS too, or the before-insert `Case.EntitlementId` stamp silently no-ops for agent-created cases. **Common failure: EntitlementProcess + milestones active but 0 milestones ever appear → it's the FLS/stamp gap, not the process.**

## 2. Service Contracts & Assets
- **`ServiceContract`** (`AccountId`, `StartDate`/`EndDate`, `Term`, `BusinessHoursId`, `Status`) + **`ContractLineItem`** (`ServiceContractId`, `Product2Id`, `AssetId`, dates). Entitlements from contracts via `Entitlement.ServiceContractId`/`ContractLineItemId`.
- Three models: (1) Entitlements only (warranty-style), (2) + Service Contracts (renewable), (3) + Contract Line Items (per-product granular — most record volume; only if you report at line granularity).
- **`Asset`** — hierarchy via `ParentId` (self-lookup) + `RootAssetId` (system-maintained — don't set manually); `AccountId`, `Product2Id`, `SerialNumber`, `InstallDate`, `Status`.
- **Warranty** (`WarrantyTerm`, `ProductWarrantyTerm`, `AssetWarranty`) is **Field-Service-gated** — objects appear only once Field Service is enabled. Define `ProductWarrantyTerm` so Assets auto-receive `AssetWarranty`.
- All standard objects → `sf data`/Apex/Bulk; layouts/RT/fields are metadata.

## 3. Incident Management (CSIM)
ITIL-style for service disruptions affecting many customers (auto-enabled in orgs created after Winter '22).
- **`Incident`** (`Subject`, `Priority`, `Status`, `IncidentNumber`, `RelatedAssetId`, `BusinessHoursId`, `StartTime`, `ResolvedDateTime` — can carry its own entitlement/milestones), **`Problem`** (root cause), **`ChangeRequest`**.
- Junctions: **`CaseRelatedIssue`** (Case ↔ Incident/Problem — attach many cases to one incident), **`ProblemIncident`** (Incident ↔ Problem), **`IncidentRelatedItem`**.
- Enable: Setup toggle (no-op if auto-enabled). **Access is profile/perm-set-gated** — grant object perms on Incident/Problem/ChangeRequest + Tab settings (deploy via `Profile`/`PermissionSet` `objectPermissions`). Slack broadcast needs the Slack app (UI/auth-gated). CSIM Flows scaffold create-from-case/broadcast/link-cases.
- Link cases programmatically by inserting `CaseRelatedIssue` rows. Put the SLA on the Incident for outage response.

## 4. Service Catalog
Self-service request catalog with fulfillment automation. **`SvcCatalogItemDef`** (metadata; `fulfillmentFlow` → a Flow), **`SvcCatalogCategory`**, **`SvcCatalogCategoryItem`**, **`SvcCatalogFulfillmentFlow`** (registers a Flow); **`SvcCatalogRequest`** (runtime object). Fulfillment flow runs on submit (create case/work order, approvals). Keep logic in reusable autolaunched subflows; set run mode explicitly (don't inherit screen-flow perms). The catalog **site** (LWR) is Experience-Builder-UI work; only the catalog metadata + flows are cleanly DX-able.

## 5. Surveys / CSAT + Service Intelligence
- **Surveys (Feedback Management):** objects `Survey`, `SurveyVersion`, `SurveyQuestion`, `SurveyInvitation`, `SurveyResponse`, `SurveySubject` (links response to Case/Account).
  - **Enablement is a UI toggle** (Setup → **Survey Settings** → flip **Surveys** on) — no clean metadata. Flipping it **auto-adds sample surveys** (`Customer Satisfaction`, `Net Promoter Score`, `Discovery Call Assessment`) + email templates, so you usually don't author a CSAT survey from scratch — reuse `Customer Satisfaction` (`SELECT Id, Name FROM Survey`). Verify enablement headlessly afterward with that SOQL.
  - **Experience Cloud Site:** the Survey Settings page has an "Experience Cloud Site" picklist that defaults to **None**. Emailed survey **invitation links need a public site to host them** — set it to a Live guest-accessible site (`SELECT Name, Status FROM Network`). Internal/authenticated survey runs work without it, but customer CSAT emails won't render a usable link until a site is chosen (a real decision — pick the public storefront/help site, not an `ESW_*` chat-embed site).
  - **CSAT on case close — the verified recipe (built in Flow Builder):** New → **Record-Triggered Flow** on `Case`, *A record is updated*, **Entry condition `Status Equals Closed`** + **"Only when a record is updated to meet the condition requirements"** (fires once on close, not every edit), **Optimize for = Actions and Related Records** (required — the Send action runs after-save). Add the **Send Survey Invitation** action with these inputs (verified, from the action's own tooltips):
    - **Survey Name = the survey's *DeveloperName*** (e.g. `customer_satisfaction`), NOT the display label. Tooltip: "Developer name of the survey for which an invitation is sent." Get it via `SELECT DeveloperName FROM Survey`.
    - **Survey Recipient = the *record Id* of the recipient** (e.g. `{!$Record.ContactId}`). Tooltip: "Id of the record to which the invitation is sent." In the value combobox type `{!$Record` to trigger the resource picker → Triggering Case → Contact ID (typing the full `{!$Record.ContactId}` string lands as a literal and won't resolve).
    - The survey must be **Active** (`Survey.ActiveVersionId` non-null — sample surveys ship active). Save → **Activate** the flow.
  - **The Flow IS metadata-deployable**, but the Send action is far easier to author in Flow Builder then `sf project retrieve`. Connect REST `generateInvitationLink` is the headless alternative.
  - **⚠️ After-save flow rollback check (do this on a live org):** a faulting Send action in an after-save record-triggered flow can **roll back the Case close**. Verify with a throwaway Person Account (fake `@example.com` email so no real customer is mailed): insert case → update Status=Closed → confirm the close succeeds AND a `SurveyInvitation` row appears; tear down (entitlement→case→account order). In testing the close was safe but **0 `SurveyInvitation` rows generated** even with the survey active + recipient + site set — invitation generation/delivery is gated by **org email deliverability** (a gmail OWEA that fails DMARC produces no invitation), and likely also needs the survey **published to the chosen Experience site + an email template**. So "flow built + active" ≠ "emails delivering" — fix the sending domain first. `SurveyInvitation` has no `Status` field; query `Id, EmailAddress`.
  - **Survey body authoring is Survey-Builder-UI-only**; Feedback-Management-license features fail silently on the base tier. Add Survey Invitation/Response related lists to Case.
- **Service Intelligence / Customer Success Score:** CRM Analytics + **Data Cloud (Data 360)** app — heavily license- + Data-Cloud-gated; install the **Service Data Kit** (Data-Cloud-UI). Treat as analytics, not CLI-buildable SLA config.

## 6. SLA reporting
- **"Cases with Milestones"** report type (Case + `CaseMilestone`: `IsViolated`, `IsCompleted`, `TargetDate`, `TimeRemainingInMins`). CSIM reporting (Incidents/Problems + related cases). Case Age + milestone violation = SLA-breach-by-age.
- `ReportType`/`Report`/`Dashboard` are **fully deployable** even though `CaseMilestone` data isn't directly creatable. Dashboard SLA compliance off `CaseMilestone.IsViolated` rate; trend reopened cases to counter TTR-gaming.

## Metadata-vs-data cheat sheet
| Area | Deployable metadata | Objects (`sf data`/Apex) | UI/license-gated |
|---|---|---|---|
| Entitlements | `EntitlementSettings`, `EntitlementProcess`, `MilestoneType`, `EntitlementTemplate`, `BusinessHoursSettings` | `Entitlement`, `CaseMilestone`, `SlaProcess`, `BusinessHours`, `Holiday` | enable toggle confirm; Classic for template→product |
| Contracts/Assets | layouts/RT/fields/flows | `ServiceContract`, `ContractLineItem`, `Asset`, `WarrantyTerm`, `ProductWarrantyTerm`, `AssetWarranty` | Warranty needs Field Service |
| Incident Mgmt | `Profile`/`PermissionSet` objectPerms, flows, flexipages | `Incident`, `Problem`, `ChangeRequest`, `CaseRelatedIssue`, `ProblemIncident` | Slack broadcast (app auth) |
| Service Catalog | `SvcCatalogItemDef`/`Category`/`CategoryItem`/`FulfillmentFlow`, `Flow` | `SvcCatalogRequest` | LWR catalog site |
| Surveys/CSAT | `Flow` (send), perms | `Survey*` runtime | Survey body authoring; Feedback Mgmt license |
| Service Intelligence | — (analytics) | — | Data Cloud + CRMA + add-on; data-kit install |
| Reporting | `ReportType`, `Report`, `Dashboard` | — | — |

## Key doc URLs
[EntitlementProcess](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_entitlementprocess.htm) · [MilestoneType](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_milestonetype.htm) · [Entitlement (Object)](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_entitlement.htm) · [CaseMilestone](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_casemilestone.htm) · [ServiceContract](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_servicecontract.htm) · [Incident](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_incident.htm) · [Send Surveys (Flow action)](https://help.salesforce.com/s/articleView?id=sf.flow_ref_elements_actions_sendsurveys.htm) · [Entitlements Implementation Guide (PDF)](https://resources.docs.salesforce.com/latest/latest/en-us/sfdc/pdf/salesforce_entitlements_implementation_guide.pdf)
