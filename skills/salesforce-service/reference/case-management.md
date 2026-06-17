# Case Management & Agent Productivity (DX reference)

> All `developer.salesforce.com/docs/atlas...` Metadata API pages are JS SPAs that don't render via fetch; element names below were cross-verified against the v67 Metadata API PDF, the `salesforcer` validators, Gearset/Metazoa docs, and Help pages. Diff against a live `sf project retrieve` before relying on exact optional fields.

## Metadata-vs-Data cheat sheet (the load-bearing distinction)
| Item | Type | DX mechanism |
|---|---|---|
| Support process | `BusinessProcess` (metadata) — **no `SupportProcess` type exists** | deploy |
| Case status/origin/priority values | `StandardValueSet` (metadata, org-global) | deploy |
| Record types | `RecordType` (metadata) | deploy |
| Assignment/Escalation/Auto-Response rules | one file per object (metadata), one active | deploy (full overwrite) |
| Queues | `Queue` (metadata) — deploy members empty | deploy + data for members |
| Case intake | `CaseSettings`, `EmailServicesFunction` (metadata) | deploy (address verify = UI) |
| Console app / utility bar / record page / compact layout / list view | `CustomApplication` / `FlexiPage` / `CompactLayout` / `ListView` | deploy |
| Quick actions / case-feed layout | `QuickAction` / `Layout<feedLayout>` | deploy |
| Classic email template | `EmailTemplate` + `EmailTemplateFolder` | deploy |
| **Macros / MacroInstruction** | **DATA** | `sf data tree` |
| **QuickText** | **DATA** | `sf data` / Bulk |
| **EnhancedLetterhead** | **DATA** | data |
| **CaseTeamRole / CaseTeamTemplate(+Member/Record)** | **DATA** | `sf data tree` |
| **CaseComment** | **DATA** | Apex / `sf data` |
| Case Swarming / Case Merge enablement | **org pref (UI-gated)** | Setup |

## 1. Case lifecycle

### Status / Origin / Priority + record types
- `Case.Status` / `Origin` / `Priority` are standard restricted picklists deployed via `StandardValueSet` (`standardValueSets/CaseStatus.standardValueSet-meta.xml`, members `CaseStatus`/`CaseOrigin`/`CasePriority`/`CaseReason`). A value's *closed* semantics come from `<closed>true</closed>` on the value, not its text.
```xml
<StandardValueSet xmlns="http://soap.sforce.com/2006/04/metadata">
  <sorted>false</sorted>
  <standardValue><fullName>Closed</fullName><default>false</default><closed>true</closed></standardValue>
</StandardValueSet>
```
- `RecordType` (`objects/Case/recordTypes/Billing.recordType-meta.xml`) references a support process via `<businessProcess>` and constrains picklist values. Assign visibility through `Profile`/`PermissionSet` `recordTypeVisibilities`.
- **Gotcha:** `StandardValueSet` is org-global — restricting *which* values a record type shows is done in the **BusinessProcess**, not per-record-type picklist edits.

### Support Process = `BusinessProcess` (there is NO `SupportProcess` type)
`objects/Case/businessProcesses/Billing_Support_Process.businessProcess-meta.xml`, package member `Case.Billing_Support_Process`:
```xml
<BusinessProcess xmlns="http://soap.sforce.com/2006/04/metadata">
  <fullName>Billing_Support_Process</fullName>
  <isActive>true</isActive>
  <values><fullName>New</fullName><default>true</default></values>
  <values><fullName>In Progress</fullName></values>
  <values><fullName>Escalated</fullName></values>
  <values><fullName>Closed</fullName></values>
</BusinessProcess>
```
Each `values` entry must already exist in the `CaseStatus` StandardValueSet, and a `RecordType` referencing the process must be in the same package (bundle them or deploy fails).

### CaseNumber auto-number
Standard field; `displayFormat` like `CASE-{00000000}` (date tokens `{YYYY}`/`{YY}`/`{MM}`/`{DD}`). The **starting/next number is UI-only and per-org** — not deployable; changing the format doesn't renumber existing records.

## 2. Assignment / Escalation / Auto-Response rules
**Universal constraint:** each category serializes as ONE file per object (`assignmentRules/Case.assignmentRules-meta.xml`, etc.); container holds N rules, each rule N `ruleEntry`, each entry N `criteriaItems` (AND/OR via `booleanFilter`) **or** a `formula`. **Only one rule active at a time. Deploy overwrites the whole file — never deploy a partial set.**

**Assignment** — `ruleEntry`: `criteriaItems`/`booleanFilter`/`formula`, `assignedTo` (queue DeveloperName or username), `assignedToType` (`Queue`|`User`), `overrideExistingTeams`, `template`, `disableEscalation`. Assign to **queues**, not individuals (lets Omni pick up). Apex DML opts in via `Database.DMLOptions.assignmentRuleHeader`; REST via `Sforce-Auto-Assign` header. Email-to-Case honors only the active rule.

**Escalation** — `ruleEntry` adds `businessHours`, `businessHoursSource`, `escalationStartTime` (`CaseCreation`|`CaseLastModified`); `escalationAction`: `minutesToEscalation`, `assignedTo`/`assignedToType`/`assignedToTemplate`, `notifyCaseOwner`, `notifyTo`/`notifyToTemplate`, `notifyEmail`. Multiple actions per entry = tiered escalation. Tie to `BusinessHours` so the clock pauses off-hours. Enable case escalation in `CaseSettings`; escalation runs on a background queue (not instant).

**Auto-Response** — `ruleEntry`: criteria + `senderEmail` (**must be a verified Org-Wide Email Address** — verification is email-gated, not deployable), `senderName`, `replyToEmail`, `template`. First match wins; no match = no auto-response.

> **Audit note:** fresh dev orgs ship *sample* rules keyed on `Account.SLA__c='Platinum'` assigned to an `epic.*@orgfarm` placeholder — "active" but inert. Replace with purpose-built rules.

## 3. Queues, Case Teams, sharing
**Queue** (`queues/Tier2_Queue.queue-meta.xml`): `name`, `doesSendEmailToMembers`, `email`, repeating `queueSobject/sobjectType` (**must list `Case`** or assignment errors "Queue not associated with this SObject type"), `queueRoutingConfig` (→ Omni `QueueRoutingConfig`), `queueMembers` (`users`/`publicGroups`/`roles`/`roleAndSubordinates`). **Best practice: deploy `queueMembers` empty** — usernames differ per org and break deploys; seed membership as data.

**Case Teams = DATA, not metadata** (invisible to `package.xml`):
- `CaseTeamRole` — `Name`, `AccessLevel` (`Read`|`Edit`|`None`), `PreferredCaseCloseSubject`.
- `CaseTeamTemplate` → `CaseTeamTemplateMember` (`TeamTemplateId`/`MemberId`/`TeamRoleId`) → `CaseTeamTemplateRecord`. Runtime `CaseTeamMember` (`ParentId`=Case).
- Deploy via `sf data create record` / `sf data tree import`; `MemberId` are org-specific User ids → re-map per org.

**Sharing:** OWD via `<sharingModel>` on the Case `CustomObject` (Private for service); criteria/owner rules via `SharingRules` metadata; programmatic via `CaseShare`. Queue membership + assignment grant implicit access.

## 4. Intake — Email-to-Case, Web-to-Case
All in **`CaseSettings`** (`settings/Case.settings-meta.xml`, deploy `-m "Settings:Case"`; **can't be packaged**).

**Email-to-Case** variants: Standard (on-prem agent — legacy), **On-Demand** (Salesforce-generated `…@email.salesforce.com` address — default modern choice; rejects >25 MB, truncates to 32,000 chars), **Enhanced Email** (makes emails first-class `EmailMessage` sObjects — keep on). `emailToCase` block: `enableEmailToCase`, `enableOnDemandEmailToCase`, `enableHtmlEmail`, `enableThreadIDInBody`/`Subject`, `overEmailLimitAction`, `unauthorizedSenderAction`, `routingAddresses` (`routingName`, `emailAddress`, `addressType`, `caseOrigin`, `caseOwner`/`caseOwnerType`, `casePriority`, `saveEmailHeaders`, `isVerified`).
- **Gotchas:** `isVerified` and the generated email-services address are **per-org runtime artifacts — not deployable** (verify via emailed link). Case record type on a routing address is a Metadata API gap → apply via assignment rules. Custom inbound = `Messaging.InboundEmailHandler` registered via `EmailServicesFunction` metadata (the Apex class must exist in the target org first).

**Web-to-Case** (`webToCase` block: `enableWebToCase`, `caseOrigin`, `defaultResponseTemplate`). Endpoint `POST https://webto.salesforce.com/servlet/servlet.WebToCase` with hidden `orgid`+`retURL`; reCAPTCHA v2 only; ~5,000 cases/day cap. **For production, prefer an Apex `@RestResource`/Screen Flow** for server-side validation, dedupe, file upload, controlled record-type/owner.

## 5. Lightning Service Console
`CustomApplication` (`applications/Service_Console.app-meta.xml`): `uiType` (`Lightning`|`Aloha`), `navType` (`Console`|`Standard`), `formFactors` (Console = Large only), `utilityBar` (→ a UtilityBar FlexiPage devName), `tabs`, `workspaceConfig/mappings`, `brand`. **App access is granted via `applicationVisibilities` in Profile/PermissionSet**, not the `.app` file. OOB Service Console = `standard__LightningService`.

**Utility Bar** = a `FlexiPage` with `<type>UtilityBar</type>` (template `one:utilityBarTemplateDesktop`); items are `componentName` (`runtime_omnichannel:agentWidget`, `console:history`, custom `c:myLwc`) with `componentInstanceProperties`. **Cannot be authored in App Builder — metadata-only.**

**Record page + Highlights Panel** = `FlexiPage` `<type>RecordPage</type>`; Highlights Panel = `force:highlightsPanel`, fields from the **`CompactLayout`** (`objects/Case/compactLayouts/`), actions from `actionNames`. **List views** = `ListView` (`objects/Case/listViews/`), `filterScope` (`Mine`/`Queue`/`Everything`/`Team`); console split view is a UI toggle over a deployed list view.

**ListView `<columns>` token format (finicky — get it wrong and the deploy fails; the cleanest way to learn it is to set columns once in the list view UI → gear → Select Fields to Display → Save → `sf project retrieve start -m "ListView:Case.AllOpenCases"`).** The tokens are report-style, NOT plain field API names, for standard/relationship fields; custom fields use the bare API name:
```xml
<columns>CASES.CASE_NUMBER</columns>   <!-- standard Case fields: CASES.SUBJECT, CASES.STATUS, CASES.PRIORITY,
<columns>NAME</columns>                      CASES.ORIGIN, CASES.RECORDTYPE, CASES.ESCALATION_STATE, CASES.CREATED_DATE, CASES.CLOSED -->
<columns>ACCOUNT.NAME</columns>        <!-- NAME = Contact name; ACCOUNT.NAME = Account; OWNER_NAME = Case Owner; CORE.USERS.ALIAS = a user alias -->
<columns>Category__c</columns>         <!-- custom field = its API name verbatim -->
```
Same token family is used in `<filters><field>` (e.g. `CASES.CLOSED` `equals` `0`, `CASES.CREATED_DATE` `equals` `LAST_N_DAYS:30`). A rich, scannable Case list view ≈ `CASE_NUMBER, NAME, ACCOUNT.NAME, SUBJECT, STATUS, PRIORITY, Category__c, ORIGIN, RECORDTYPE, OWNER_NAME, ESCALATION_STATE, CREATED_DATE` — mirror the page-layout fields but keep it ~12 columns for scannability, and tailor closed-case views (swap `ESCALATION_STATE`→`Resolution__c` + add `CASES.CLOSED_DATE`). Each list view's columns are independent — apply the set to every actively-used view (All Open, My Open, the queue view) via one deploy.

## Custom service LWC + assembling the Case record page (hard-won)
A "real service console" feel comes from a custom LWC on the Case record page showing **SLA milestone countdowns + entitlement + service contract + order context** in one card. Pattern that works:
- **Apex controller** `with sharing`, `@AuraEnabled(cacheable=true) getServiceInfo(Id caseId)` returning milestones + entitlement + contract + account/order. Query `CaseMilestone` (`MilestoneType.Name`, `TargetDate`, `CompletionDate`, `IsCompleted`, `IsViolated`) and the Case's `Entitlement.SlaProcess.Name` / `Entitlement.ServiceContract.*`. **Wrap the entitlement query in try/catch + `Database.query`** because `Case.EntitlementId` is FLS-gated (see entitlements ref) — degrade gracefully so the panel still renders the empty state for users without FLS.
- **LWC** (`lightning__RecordPage`, target object `Case`): `@wire(getServiceInfo,{caseId:'$recordId'})`; a **live countdown** via `setInterval(()=>{this.now=Date.now()},1000)` in `connectedCallback` (clear in `disconnectedCallback`) + a getter that recomputes "Xh Ym Zs left / Overdue by …" against each milestone's TargetDate. Reactive class fields → the timer re-renders every second. Verified live: First Response shows e.g. "3h 58m 41s left".
- **Place it on the Case record page (FlexiPage):** there is usually **no custom Case record page** (org uses the system default), and **activation as org-default is UI-only** — so you create/activate in Lightning App Builder. Component **drag-drop is NOT reliably automatable** (HTML5 drag); use the deterministic alternative: **double-click the palette component → "Select an insertion point" prompt → OK → click the blue insertion indicator on the canvas → click the palette component again** to drop it. Then **Save** (first save of a system-default clone creates `Case_Record_Page`; you MUST add a real component to enable Save — editing the Description doesn't dirty it) → **Activate → Assign as Org Default** (pick Desktop+Phone). After it exists, **retrieve it to version-control** (`sf project retrieve -m "FlexiPage:Case_Record_Page"`).
- **FlexiPage record-page tokens (verified, for hand-authoring/diffing):** template `flexipage:recordHomeTemplateDesktop`; components `force:highlightsPanel`, `force:detailPanel`, `force:relatedListContainer`, `forceChatter:recordFeedContainer`, `flexipage:tabset`/`flexipage:tab`, **`forceKnowledge:articleSearchDesktop`** (the Knowledge component for human agents — previously-undocumented token, now confirmed), and a custom LWC as bare `<componentName>caseServicePanel</componentName>` (no `c:` prefix in FlexiPage XML).

## 6. Productivity (mostly DATA)
- **Macros = DATA:** `Macro` (`Name`, `IsBulk`, `StartingContext`) + `MacroInstruction` children. Deploy via `sf data tree`. Invisible to `package.xml`.
- **Quick Text = DATA:** `QuickText` (`Name`, `Message` rich text, `Category`, `Channel` multi-select `Email;Phone;Internal;Portal`). The Category/Channel *picklist values* are field metadata; the rows are data. Also surface in MIAW and feed Einstein reply grounding.
- **Email templates:** Classic = `EmailTemplate` metadata (`.email` + `.email-meta.xml`, folder `EmailTemplateFolder`, public token `unfiled$public`). Lightning = same `EmailTemplate` type flagged `UiType='SFX'` (Classic=`Aloha`) — no separate type. **Enhanced Letterhead = `EnhancedLetterhead` DATA**; classic `Letterhead` is metadata.
- **Case Feed:** `Layout`'s `<feedLayout>` element; publisher actions via `<quickActionList>`. Quick actions = `QuickAction` type (`Case.SendEmail`, `Case.LogACall`). **Gotcha:** Email Deliverability = "No access" hides `Case.SendEmail` and **fails any layout deploy referencing it** — flip deliverability on first.

## 7. Swarming / Merge / Comments
- **Case Swarming** — Setup toggle (UI-gated) + `Swarming` perm set; add the "Begin Swarming" Flow as a Case `QuickAction`. Runtime: `Swarm`/`SwarmMember`/`SwarmParticipant`.
- **Case Merge** — org setting + permission (UI-gated); not the standard `merge` DML (that's Lead/Contact/Account).
- **Case Comments** — `CaseComment` sObject (`ParentId`, `CommentBody`, `IsPublished`) — data; newer orgs prefer Case Feed/Chatter.

## 8. Service reporting
- KPIs from `Case` fields: `Age`, `ClosedDate`, `IsClosed`, `IsEscalated`, `Status`, `Priority`, `Origin`, `OwnerId`. First-response/CSAT have **no native field** — model first-response as a `CaseMilestone` or custom datetime stamped on first outbound `EmailMessage`; CSAT as a custom field or Feedback Management Survey.
- Metadata: `ReportType` (`deployed=true`), `Report` (folder `ReportFolder`), `Dashboard` (folder `DashboardFolder`) — all deployable. Ship a "Service Performance" dashboard: open by Status/Priority/Owner, avg Age, escalated, milestone `IsViolated`, CSAT trend.

## Key doc URLs
- [BusinessProcess](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_businessprocess.htm) · [RecordType](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_recordtype.htm) · [StandardValueSet](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_standardvalueset.htm)
- [AssignmentRules](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_assignmentrule.htm) · [EscalationRules](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_escalationrules.htm) · [AutoResponseRules](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_autoresponserules.htm)
- [Queue](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_queue.htm) · [CaseSettings](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_casesettings.htm) · [CustomApplication](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_customapplication.htm) · [FlexiPage](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_flexipage.htm)
- [CaseTeamRole](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_caseteamrole.htm) · [QuickAction](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_quickaction.htm) · [InboundEmail (Apex)](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_classes_email_inbound_using.htm) · [Email-to-Case Threading](https://help.salesforce.com/s/articleView?id=service.support_email_to_case_threading.htm)
