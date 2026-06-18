# Field Service — Scheduling & Optimization

The scheduling engine lives in the **FSL managed package** (`FSL` namespace, `FSL__*` objects), layered on the core objects. Everything with an `FSL__` prefix or `FSL.` Apex namespace is managed-package, not core.

## 1. Scheduling Policies (`FSL__Scheduling_Policy__c`)
A policy = **work rules** (hard pass/fail filters → candidate list) **+ service objectives** (weighted soft goals → rank survivors). Work rules answer "who *can*"; objectives answer "who is *best*."
- `FSL__Scheduling_Policy__c` — header.
- `FSL__Scheduling_Policy_Work_Rule__c` — junction policy ↔ work rule.
- `FSL__Scheduling_Policy_Goal__c` — junction policy ↔ service objective, **carrying that objective's `FSL__Weight__c` for this policy** (same objective, different weight per policy).

**Four standard policies the package seeds** (clone, don't edit):
| Policy | Purpose |
|---|---|
| **Customer First** | Best customer experience — Preferred Resource + ASAP weighted high. Common default. |
| **High Intensity** | Max throughput / pack the day (heavy Minimize Travel / Minimize Gaps). |
| **Soft Boundaries** | Share resources across territories at peak — relax territory hardness (relies on secondary/relocation members). |
| **Emergency** | Instant dispatch of one urgent SA via the Emergency wizard; few rules. |

Set the org default: Field Service Settings → Scheduling/Global Actions → **Default Scheduling Policy**. Dispatchers can override per action; booking/Apex pass a policy Id explicitly.

## 2. Work Rules (`FSL__Work_Rule__c`) — hard constraints
`FSL__Type__c` selects the logic:
| Type | Constrains |
|---|---|
| Match Skills | Resource holds required `SkillRequirement` (+ level). |
| Match Territory / Working Territories | Resource is a `ServiceTerritoryMember` of the SA's territory. |
| Match Fields / Match Boolean / Match Time | Field-to-field equality / boolean / time-window between SA and resource. |
| Extended Match | Custom matching via a junction object (most flexible). |
| Required Resources / Excluded Resources | Honors `ResourcePreference` Required/Excluded. |
| **Service Resource Availability** | Resource is actually free — respects absences, breaks, travel, gaps. **Every policy needs one or absences are ignored.** |
| Service Crew Resources Availability | (Apex) crew meets the parent's minimum crew size. |
| Service Appointment Visiting Hours / Working Hours | Within customer visiting hours / resource shift. |
| Count Rule | Caps assignments/hours/custom value over a period. |
| Maximum Travel From Home | Distance/time from home base. |
| TimeSlot Designated Work / Work Capacity | Reserved slots for a work type / per-resource capacity. |
Apex-extensible via **Extended Match** and Apex work rules; most others are config-only.

## 3. Service Objectives / Goals (`FSL__Service_Goal__c`) — soft, weighted
Grade candidates 0–1, never eliminate. Standard: **ASAP, Minimize Travel, Preferred Resource, Resource Priority, Minimize Overtime, Minimize Gaps, Group Nearby Appointments, Skill Level.**

**Scoring:** each grade × its weight (`FSL__Scheduling_Policy_Goal__c.FSL__Weight__c`), summed, plus the **SA priority** as a large additive term (priority 1 ≈ 25,500; priority 10/null ≈ 1,000). **Rule of thumb: Minimize Travel won't dominate unless its weight > the sum of the other objectives' weights** in that policy.

## 4. Scheduling operations
**Per-appointment (dispatcher/quick actions):** Schedule/Auto-Schedule, drag-and-drop, **Candidates** (graded resource+slot list, `FSL.GradeSlotsService.getGradedMatrix`), Book Appointment (§5), **Emergency**, **Reshuffle** (bump lower-priority to fit a high-priority one), **Fill-In Schedule** (fill gaps), **Group Nearby** (cut travel).

**Bulk optimization:**
- **Global Optimization** — re-optimize many SAs across territories over a range; usually a scheduled nightly job. **~21-day horizon limit** out of the box (chain requests for longer).
- **In-Day Optimization** — re-optimize a territory on the day of service.
- **Resource Schedule Optimization (RSO)** — one resource's day.

Each run creates an **`FSL__Optimization_Request__c`** (status/policy/range/scope). **Optimization is asynchronous** — enqueue, then poll the request record for completion. The optimizer runs as a designated **background/optimization user** that needs the optimization perms ("Not Authorized" otherwise — KB 000389399).

## 5. Appointment booking — arrival windows
Customers pick a window (e.g., "9:30–11:30 Jan 5"); the engine assigns the exact slot/resource later.
- **Book Appointment** quick action / Lightning component (configured with a default policy + operating hours; the operating-hours time-slot length defines offered windows). **Candidates** = internal graded options.
- Apex:
```apex
List<FSL.AppointmentBookingSlot> slots = FSL.AppointmentBookingService.getSlots(
    Id serviceAppointmentId, Id schedulingPolicyId, Id operatingHoursId,
    System.TimeZone tz, String sortBy /* 'grade'|'starttime' */, Boolean exactAppointments);
```
(sibling `getSlotsWithFilter`). Booking respects the SA's `EarliestStartPermitted`/`DueDate`. `exactAppointments` flips window-vs-exact behavior.

## 6. Scheduling recipes & automated scheduling
**Scheduling Recipes** (Field Service Settings → Automated Scheduling → Scheduling Recipes → New): "when *event* (SA canceled / completed early / cannot complete / gap), for these status categories + initiating users, run *operation* with *this policy*, set this status." No-code in-day reactivity (`pfs_create_scheduling_recipe`).
**Auto-schedule on create / custom triggers:** Flow/Process on criteria → invocable Apex → `FSL.ScheduleService.schedule` (or a `@future` building an OAAS optimization request). The FSL dev framework also exposes Field Service **custom triggers**.

## 7. Default policy, running the optimizer, licensing
- Default policy: Field Service Settings → Scheduling. Build/clone via Guided Setup → Customize Scheduling Policies.
- Run optimizer: Field Service Admin → Optimization → Optimize (territories + horizon + policy), or schedule it recurring; RSO/in-day from the Gantt or recipes.
- **Licenses:** Field Service Standard (all users); **Field Service Scheduling** PSL (resource is *included in optimization* — unlicensed = silently gets no work); **Field Service Dispatcher** PSL (console + optimization actions). Assign via Guided Setup.

## 8. FSL Apex API (DX/programmatic) vs UI vs metadata
**Apex (`FSL` namespace):**
- `FSL.ScheduleService.schedule(policyId, serviceAppointmentId)` — schedule one SA.
- `FSL.ScheduleService.scheduleExtended(...)` — chained/related work (**requires ES&O**, assumes synchronous).
- `FSL.ScheduleService.getAppointmentInsights(...)` — why an SA can't be scheduled.
- `FSL.GradeSlotsService.getGradedMatrix(policyId, serviceAppointmentId)` — candidate grades.
- `FSL.AppointmentBookingService.getSlots(...)` / `getSlotsWithFilter(...)` — arrival-window slots.
- `FSL.OAAS` + `FSL.OAASRequest` — Optimization as a Service: build a request (policy id, start/finish, territory scope, `filterByFieldAPIName` boolean SA field, all-or-nothing) → `FSL.OAAS().optimize(request)`. Creates an `FSL__Optimization_Request__c`.

**UI-only (last-resort browser):** enabling FS + installing the package; Guided Setup; building/editing policies/work-rules/objectives; Scheduling Recipes; the Dispatcher Console actions; activating the optimizer/ES&O.

**ES&O note:** Salesforce is migrating to **Enhanced Scheduling and Optimization** (`fs_eso_overview`, org pref `o2EngineEnabled`). It changes behaviors and is a prerequisite for `scheduleExtended`. Confirm whether the org is on ES&O before relying on legacy OAAS (sync vs async, 21-day horizon differ).
- **⚠️ `FSL.ScheduleService.schedule()` → `FSL.Exceptions.GeneralException: Schedule optimization incomplete`** (verified): once `o2EngineEnabled=true`, `schedule()` routes through the ES&O optimization engine. If ES&O's backend optimization service isn't fully provisioned (common in **Developer Edition** after just flipping the org pref — provisioning is async/may need the guided ES&O enablement to finish), every `schedule()`/optimize call throws this, and the new Scheduling Console shows "couldn't load availability" — **same root cause**. The data can be 100% correct (it's not your config).
  - **Reliable fallback that always works (no optimizer): MANUAL DISPATCH.** Set `ServiceAppointment.SchedStartTime`/`SchedEndTime` (a business-hours slot inside the SA window, in UTC — mind the territory OH timezone), `Status='Scheduled'`, and `insert new AssignedResource(ServiceAppointmentId=…, ServiceResourceId=…)`. The FSL package accepts it with no errors, and it renders on the **Classic Dispatch Console** Gantt (date-navigate to the slot day). This is exactly what a dispatcher does by drag-drop and what the no-package auto-scheduler Queueable does — proves the whole data model end-to-end independent of the optimizer.

## Why the optimizer picks (or silently ignores) a resource — verified live with multiple techs
Set up a multi-resource territory and `FSL.ScheduleService.schedule()` only ever assigns ONE tech? Work through this in order:
1. **Candidacy gate #1 — the Scheduling USER PERMISSION.** Each candidate resource's **user** needs `PermissionsFieldServiceScheduling` (granted by the **`FSL_Resource_License`** perm set). The Field Service Scheduling **PSL/license alone is NOT enough.** Missing it = the resource is silently dropped from the candidate pool, shows up as fewer resources than members in the Scheduling Console, and a skill-unique SA for that resource won't schedule at all. A System-Admin-based resource masks this (Admin profile grants the perm). Full detail + the exact error in [dispatcher-console-permissions.md](dispatcher-console-permissions.md).
2. **License cap.** Field Service Scheduling is a *counted* PSL (e.g., a Dev org has 2). You can only have as many schedulable techs as you have licenses; extra resources are valid records but never candidates.
3. **Eligibility (hard work rules).** Match Skills (resource holds the SA's `SkillRequirement`s — from the WorkType/WO), Match Territory (primary/secondary member of the SA's territory, membership effective on the date), Resource Availability (working hours/time slots, no clashing absence).
4. **Ranking (soft objectives) — the policy decides, and Customer First is NOT travel-first.** Verified Customer First weights: **Preferred Service Resource 4, ASAP 4, Minimize Travel 2, Resource Priority 1.** So the *nearest* tech doesn't necessarily win — **availability/ASAP dominates** (a free tech beats a closer-but-busier one). To make **distance** the deciding factor, use **High Intensity** (travel-heavy) or clone a policy and raise Minimize Travel's weight above the sum of the others.
5. **Home base for travel.** Future-dated travel uses the resource's **home base = `ServiceResource.LocationId` (a `Location`)**; `LastKnownLatitude/Longitude` is the *real-time GPS* for in-day (its `LastKnownLocationDate` is **not directly writable** via DML). No home-base Location → travel can't differentiate resources, so Minimize Travel contributes ~0 and ties fall to ASAP/priority.

## Gotchas
- **Schedule ONE SA per transaction.** Calling `FSL.ScheduleService.schedule()` for several SAs in a single Apex execution makes the 1st succeed and the rest throw `FSL.Exceptions.GeneralException: Schedule optimization incomplete` (engine busy). Run each in its own transaction (separate `sf apex run` / Queueable). Likewise **unschedule and re-schedule the same SA in SEPARATE transactions** or you get a transient "The time slot or resource is no longer available. Try again."
- **`schedule()` returns success even when nothing was scheduled** — if no eligible candidate, the SA just stays `Status='None'` with no `AssignedResource` and NO exception. Always re-query to confirm an assignment; don't trust the absence of an error.
- **Clone the standard policies — never edit in place** (upgrades touch originals).
- **Every policy needs a Service Resource Availability work rule** or absences/breaks are ignored (silent over-booking).
- **Objective weights are per-policy**, not global.
- **Minimize Travel needs weight > sum of other objectives'** to dominate.
- **Priority is additive and huge** — a high-priority SA can swamp all objective scoring; null = lowest.
- **Optimization is async** — poll `FSL__Optimization_Request__c`; don't expect inline results. ~21-day global horizon (chain for longer).
- **"Not Authorized" after optimization** = the background/optimization user lacks the optimization perm set/PSL.
- **`scheduleExtended` requires ES&O**; resources need the **Scheduling PSL** to be optimized.
- **Soft Boundaries needs secondary/relocation members** to actually be "soft"; **Emergency policy is for the one-shot wizard**, not bulk.
- **Verify `FSL.OAAS`/`OAASRequest` property casing** against the org's `FSL` describe before coding (developer-guide pages are JS-rendered).

Help slugs: `service.pfs_scheduling.htm`, `service.pfs_optimization_theory_work_rules.htm`, `service.pfs_scheduling_services.htm`, `service.fs_start_optimization.htm`, `service.pfs_optimization.htm`, `service.pfs_monitor_optimization_requests.htm`, `service.pfs_create_scheduling_recipe.htm`, `service.fs_eso_overview.htm`, `sf.fs_perm_set_licenses.htm`. Dev guide: `apex_namespace_FSL.htm`, `apex_class_FSL_AppointmentBookingService.htm`, `apex_class_FSL_ScheduleService.htm`, `apex_class_FSL_OAAS.htm`. Reference repos: `iampatrickbrinksma/SFS-Utils`, `.../SFS-LongTermOptimization`.
