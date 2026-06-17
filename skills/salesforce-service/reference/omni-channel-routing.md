# Omni-Channel Routing (DX reference)

> Field shapes assembled from a live Summer '26 retrieve + help.salesforce.com. Pull the verbatim XSD with `sf project retrieve start -m "ServiceChannel,RoutingConfiguration,PresenceUserConfig,ServicePresenceStatus"` before relying on exact optional fields.

## Mental model
A **work item** (Case, `MessagingSession`, `LiveChatTranscript`, voice call, custom obj) enters Omni → a **`PendingServiceRouting` (PSR)** record carries the decision (model, priority, capacity, skills) → Omni matches agents whose **`UserServicePresence`** status is online for that **`ServiceChannel`** with spare **capacity** → creates an **`AgentWork`** record. PSR is created **declaratively** (queue routing fires / Omni-Channel Flow Route Work) or **programmatically** (`insert PendingServiceRouting`).

## 1. Enable — `OmniChannelSettings`
`settings/OmniChannel.settings-meta.xml`: `enableOmniChannel`, `enableOmniSkillsRouting` (skills + direct-to-agent — **turn on day one**, retrofitting re-cuts configs), `enableOmniSecondaryRoutingPriority`. Deploy `-m "Settings:OmniChannel"`. **Enablement-gated:** downstream Omni metadata silent-no-ops if this isn't deployed first. Headless nudge: `sf org open --path "/lightning/setup/OmniChannelSettings/home" --url-only`.

## 2. Routing models
| Model | What | When |
|---|---|---|
| **Queue-based** | queue's `RoutingConfiguration` pushes; Most Available vs Least Active | simple teams |
| **Skills-based** | routed by required Skills (+ levels) via PSR/`SkillRequirement` or attribute rules | expertise/language/product matching |
| **External** | 3rd-party engine decides via Omni REST API; `routingModel=External` | existing external ACD/CCaaS |
| **Omni-Channel Flow** | a `RoutingFlow` inspects the work item and calls **Route Work** (queue/skills/**bot**/agent + fallback) | **modern default** for messaging/voice; how MIAW reaches Agentforce |

## 3. Core metadata types & shapes
### `ServiceChannel` (`serviceChannels/<Name>.serviceChannel-meta.xml`)
Declares a routable work type. `label`, `relatedEntity` (the routed sObject, e.g. `MessagingSession`), `relatedEntityType`, `isStatusCapacityModel` (true = status-based capacity), `secondaryRoutingPriorityField`, `customConsoleFooterComponent`. Standard ones: `sfdc_livemessage` (messaging), `sfdc_phone` (voice).

### `RoutingConfiguration` (a.k.a. object `QueueRoutingConfig`) — **naming trap**
**Metadata API type is `RoutingConfiguration`** (folder `routingConfigs/`, Setup label "Routing Configuration"); the **SOAP/Tooling object** backing it is **`QueueRoutingConfig`**. Don't look for a metadata type named `QueueRoutingConfig`.
```xml
<RoutingConfiguration xmlns="http://soap.sforce.com/2006/04/metadata">
  <label>Messaging Routing</label>
  <routingModel>MostAvailable</routingModel>   <!-- MostAvailable | LeastActive | External -->
  <routingPriority>1</routingPriority>          <!-- lower = routed first across channels -->
  <isAttributeBased>false</isAttributeBased>     <!-- true for attribute/skills-based -->
  <capacityValue>1</capacityValue>               <!-- or capacityPercentage -->
  <pushTimeout>20</pushTimeout>                  <!-- seconds before auto-decline/re-route; 0=off -->
</RoutingConfiguration>
```

### Queue link
`Group` Type=Queue carries the routing config; in metadata `Queue` holds `<queueRoutingConfig>` + supported sObject types (`queueSobject`). Add the ServiceChannel's `relatedEntity` to the queue's objects.

### Presence metadata
- `ServicePresenceStatus` (`servicePresenceStatuses/`) — an agent online status + the `<channels>` it's available for. **Without presence statuses + assigned agents, a fallback queue has nobody "Available" → "Agents are not available."**
- `PresenceUserConfig` — per-agent **capacity** profile (`assignedUsers`/`assignedProfiles`, statuses, decline options).
- `PresenceConfigDeclined` / `PresenceDeclineReason` — decline behavior + reasons.
- Capacity models: **status-based** (`ServiceChannel.isStatusCapacityModel=true`, weighted per status — use for messaging) vs **work-item/tab** (per open item).
- **Deploy order:** Settings → ServiceChannel → RoutingConfiguration → Queue → ServicePresenceStatus → PresenceUserConfig → Flow. (`ServicePresenceStatus` deploy depends on the referenced ServiceChannels existing.)

## 4. Skills-based routing
Prereq `enableOmniSkillsRouting=true`. Building blocks: `Skill` (metadata, `skills/`), `SkillRequirement` (object: `RelatedRecordId`=the PSR id, `SkillId`, `SkillLevel` 0–10, `AdditionalSkillId`), `WorkSkillRouting` (attribute → skill map, declarative, `RoutingConfiguration.isAttributeBased=true`). Three ways to attach skills: Apex PSR, Omni-Channel Flow "Add Skill Requirements" element, or Skill-Based Routing Rules. Set a **Drop Additional Skills Timeout** to widen the match if no fully-skilled agent frees up.

## 5. Programmatic routing (Apex)
**`PendingServiceRouting`** key fields: `WorkItemId`, `ServiceChannelId`, `RoutingType` (`SkillsBased`|`Queue`), `RoutingModel` (`MostAvailable`|`LeastActive`), `RoutingPriority`, `CapacityWeight`, `IsReadyForRouting` (**the trigger**), `PushTimeout`, `DropAdditionalSkillTimeout`, `SecondaryRoutingPriority`.
```apex
// Two-phase: insert NOT ready → attach skills → flip to ready
PendingServiceRouting psr = new PendingServiceRouting(
  WorkItemId=caseId, RoutingType='SkillsBased', RoutingPriority=1, CapacityWeight=1,
  ServiceChannelId=channelId, RoutingModel='MostAvailable', IsReadyForRouting=false);
insert psr;
insert new SkillRequirement(RelatedRecordId=psr.Id, SkillId=skillId, SkillLevel=5);
psr.IsReadyForRouting = true; update psr;
```
**Why two-phase:** `IsReadyForRouting=true` on insert routes *immediately*, before SkillRequirements exist → skills ignored.

`AgentWork` (the assignment — `Status` Assigned/Opened/Declined/Closed, `AgentId`, `WorkItemId`, `CapacityWeight`); `UserServicePresence` (live presence — `UserId`, `ServicePresenceStatusId`, `ConfiguredCapacity`, `IsCurrentState`). `ConnectApi.Routing` + the LWC/Aura Omni Toolkit API (`setServicePresenceStatus`, accept/decline) drive the console.
- **Gotcha:** a PSR routes only to agents whose **current** presence includes the work's `ServiceChannel` — no one online for that channel → it sits pending ("Agents are not available").

## 6. Omni-Channel Flow + Route Work — the web-chat→agent spine (CRITICAL)
Web chat (MIAW) does **NOT** bind to an agent directly. The MessagingSession enters an **Omni-Channel Flow** (`Flow` `<processType>RoutingFlow</processType>` — confirmed live) and a **Route Work** action sends it to a bot/queue/skills/agent + fallback.
1. Flow Builder → **Omni-Channel Flow**; auto input var **`recordId`** = the work item id (the MessagingSession id for messaging). Other inputs: `skillList`, `prechat`.
2. (Optional) Get/Update Records on the MessagingSession to read/stamp identity.
3. **Route Work** action (must be **last** on its path): Routing Type (Skill/Queue-based), Service Channel, Queue, Skills, **Bot** (the **Bot picker covers Agentforce agents** — only *active* ones show), **Fallback Queue** (always set), Allow Decline, Capacity, Drop Additional Skills Timeout, Routing Attributes.
4. **Activate** the flow; select it on the messaging channel / Embedded Service routing config (`sessionHandlerType=Flow`, `sessionHandlerFlow=<api>`), or on the Bot's Inbound Omni-Channel Flows.
- **Bot→human transfer (outbound):** set a **Default Outbound Flow** on the Bot Overview; the outbound flow Route Works to queue/rep/skill with availability handling.
- **Pass identity:** Update Records on the MessagingSession custom field from the channel/pre-chat param; the agent variable must be **`linked`** to that field (not mutable); test in a **new** session.

## 7. External routing & secondary priority
- **External:** `RoutingConfiguration.routingModel=External` + a dedicated queue + Omni-Channel REST API integration; Salesforce won't auto-match. Don't mix with queue/skills on the same channel.
- **Secondary routing priority** (gated by `enableOmniSecondaryRoutingPriority`): tie-breaker within a queue — set `ServiceChannel.secondaryRoutingPriorityField` to a populated field on the work object (stamp it before `IsReadyForRouting=true`).

## 8. Supervisor / EWT / deflection
- **Omni Supervisor** — real-time console (backlog, presence, AgentWork, reassign/raise priority); data is queryable via `AgentWork`/`UserServicePresence`.
- **Estimated Wait Time** — show MIAW customers a live estimate; reps see per-queue/skill EWT before transfer. Can drive a "long wait → keep in bot / offer callback" branch.
- Bot-first deflection: Route Work to the bot, escalate only on intent/failure to the fallback queue.

## Quick-reference: types → folders → backing objects
```bash
sf project retrieve start -m "Settings:OmniChannel,ServiceChannel,RoutingConfiguration,Queue,ServicePresenceStatus,PresenceUserConfig,PresenceDeclineReason,Skill,WorkSkillRouting,Flow"
```
| Concept | Metadata type | Folder | Backing object |
|---|---|---|---|
| Enablement | `OmniChannelSettings` | settings/ | — |
| Work type | `ServiceChannel` | serviceChannels/ | ServiceChannel |
| Routing template | `RoutingConfiguration` | routingConfigs/ | **QueueRoutingConfig** |
| Queue | `Queue` | queues/ | Group/QueueSObject |
| Online status | `ServicePresenceStatus` | servicePresenceStatuses/ | ServicePresenceStatus |
| Capacity/user cfg | `PresenceUserConfig` | presenceUserConfigs/ | — |
| Routing flow | `Flow` (RoutingFlow) | flows/ | — |
| Runtime pending | — | — | `PendingServiceRouting` + `SkillRequirement` |
| Runtime assignment | — | — | `AgentWork` |
| Runtime presence | — | — | `UserServicePresence` |

## Key gotchas
1. Enable Omni first (downstream silent-no-ops). 2. `RoutingConfiguration` ≠ a type named `QueueRoutingConfig`. 3. Web chat → agent needs Flow + Route Work (last on path), an active agent, a fallback queue. 4. PSR two-phase (not-ready → skills → ready). 5. Pass identity via the MessagingSession field; agent var `linked`; test in a NEW session. 6. "Agents are not available" = presence/routing config, not the agent.

## Key doc URLs
[OmniChannelSettings](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_omnichannelsettings.htm) · [ServiceChannel](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_servicechannel.htm) · [QueueRoutingConfig](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_queueroutingconfig.htm) · [PendingServiceRouting](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_pendingservicerouting.htm) · [AgentWork](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_agentwork.htm) · [Create an Omni-Channel Flow](https://help.salesforce.com/s/articleView?id=service.omnichannel_create_a_flow.htm) · [Route Messaging Sessions with Omni-Channel Flows](https://help.salesforce.com/s/articleView?id=service.messaging_routing_flows.htm)
