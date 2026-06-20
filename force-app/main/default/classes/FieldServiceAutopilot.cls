/**
 * FieldServiceAutopilot
 * On Service Appointment creation:
 *   1) BEFORE INSERT  — ensure the SA has a ServiceTerritory (geofence mapping):
 *        a) inherit from the parent WorkOrder's territory, else
 *        b) nearest active ServiceTerritory by the SA's geolocation.
 *   2) AFTER INSERT   — async ES&O auto-scheduling: FSL.ScheduleService.schedule()
 *        assigns the best technician by skills + availability + scheduling policy
 *        (default "Customer First"). Runs in a chained Queueable so each schedule
 *        runs in its own transaction (ES&O makes callouts; avoids same-tx locks).
 * Defensive: never blocks SA insert; scheduling failures are swallowed + logged.
 */
public with sharing class FieldServiceAutopilot {

    // Test seam — set true in tests to skip the async schedule enqueue.
    @TestVisible static Boolean skipSchedule = false;
    // Scheduling policy used for auto-assignment (overridable for tests/config).
    @TestVisible static String policyName = 'Customer First';

    /** BEFORE INSERT: map each territory-less SA to a ServiceTerritory. */
    public static void assignTerritories(List<ServiceAppointment> news) {
        Set<Id> woIds = new Set<Id>();
        for (ServiceAppointment sa : news) {
            if (sa.ServiceTerritoryId == null && sa.ParentRecordId != null
                && sa.ParentRecordId.getSObjectType() == WorkOrder.SObjectType) {
                woIds.add(sa.ParentRecordId);
            }
        }
        Map<Id, WorkOrder> wos = woIds.isEmpty()
            ? new Map<Id, WorkOrder>()
            : new Map<Id, WorkOrder>([SELECT Id, ServiceTerritoryId FROM WorkOrder WHERE Id IN :woIds]);

        List<ServiceTerritory> terrs = [
            SELECT Id, Latitude, Longitude FROM ServiceTerritory
            WHERE IsActive = true AND Latitude != null AND Longitude != null
        ];

        for (ServiceAppointment sa : news) {
            if (sa.ServiceTerritoryId != null) continue;
            // 1) inherit from parent WorkOrder
            if (sa.ParentRecordId != null && wos.containsKey(sa.ParentRecordId)
                && wos.get(sa.ParentRecordId).ServiceTerritoryId != null) {
                sa.ServiceTerritoryId = wos.get(sa.ParentRecordId).ServiceTerritoryId;
                continue;
            }
            // 2) nearest active territory by geolocation
            if (sa.Latitude != null && sa.Longitude != null && !terrs.isEmpty()) {
                Id best;
                Double bestKm;
                for (ServiceTerritory t : terrs) {
                    Double km = distanceKm(sa.Latitude, sa.Longitude, t.Latitude, t.Longitude);
                    if (bestKm == null || km < bestKm) { bestKm = km; best = t.Id; }
                }
                sa.ServiceTerritoryId = best;
            }
        }
    }

    /** AFTER INSERT: enqueue ES&O auto-scheduling for unscheduled, territory-bound SAs. */
    public static void autoSchedule(List<ServiceAppointment> news) {
        if (skipSchedule) return;
        List<Id> toSchedule = new List<Id>();
        for (ServiceAppointment sa : news) {
            if (sa.Status == 'None' && sa.ServiceTerritoryId != null) toSchedule.add(sa.Id);
        }
        if (toSchedule.isEmpty()) return;
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        System.enqueueJob(new AutoScheduleQueueable(toSchedule));
    }

    static Double distanceKm(Decimal a1, Decimal o1, Decimal a2, Decimal o2) {
        Double la1 = a1.doubleValue(), lo1 = o1.doubleValue(), la2 = a2.doubleValue(), lo2 = o2.doubleValue();
        Double r = 6371.0, dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
        Double a = Math.sin(dLa / 2) * Math.sin(dLa / 2)
            + Math.cos(rad(la1)) * Math.cos(rad(la2)) * Math.sin(dLo / 2) * Math.sin(dLo / 2);
        return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    }
    static Double rad(Double d) { return d * Math.PI / 180.0; }

    private static final Set<String> SA_OPEN =
        new Set<String>{ 'None', 'Scheduled', 'Dispatched', 'In Progress' };

    /**
     * AFTER UPDATE: roll Service Appointment progress up to the parent Work Order.
     *  - SA -> In Progress / Dispatched : WO -> In Progress (so the Case -> Working)
     *  - SA -> Completed : if NO sibling SA is still open, WO -> Completed
     *    (a pending return visit keeps the WO open). WO change then drives the Case.
     */
    public static void syncWorkOrders(List<ServiceAppointment> news, Map<Id, ServiceAppointment> oldMap) {
        Set<Id> woCompleteCandidates = new Set<Id>();
        Set<Id> woInProgress = new Set<Id>();
        for (ServiceAppointment sa : news) {
            if (sa.ParentRecordId == null || sa.ParentRecordId.getSObjectType() != WorkOrder.SObjectType) continue;
            String oldStatus = oldMap.get(sa.Id).Status;
            if (oldStatus == sa.Status) continue;
            if (sa.Status == 'Completed') woCompleteCandidates.add(sa.ParentRecordId);
            else if (sa.Status == 'In Progress' || sa.Status == 'Dispatched') woInProgress.add(sa.ParentRecordId);
        }
        if (woCompleteCandidates.isEmpty() && woInProgress.isEmpty()) return;

        // For completion candidates, check whether any sibling SA is still open.
        Set<Id> stillOpen = new Set<Id>();
        if (!woCompleteCandidates.isEmpty()) {
            for (ServiceAppointment sib : [
                SELECT ParentRecordId, Status FROM ServiceAppointment
                WHERE ParentRecordId IN :woCompleteCandidates AND Status IN :SA_OPEN
            ]) {
                stillOpen.add(sib.ParentRecordId);
            }
        }

        Map<Id, WorkOrder> updates = new Map<Id, WorkOrder>();
        for (Id woId : woInProgress) updates.put(woId, new WorkOrder(Id = woId, Status = 'In Progress'));
        for (Id woId : woCompleteCandidates) {
            if (!stillOpen.contains(woId)) updates.put(woId, new WorkOrder(Id = woId, Status = 'Completed'));
        }
        if (updates.isEmpty()) return;

        // Don't overwrite WOs already at/after the target.
        List<WorkOrder> toUpdate = new List<WorkOrder>();
        for (WorkOrder cur : [SELECT Id, Status FROM WorkOrder WHERE Id IN :updates.keySet()]) {
            WorkOrder desired = updates.get(cur.Id);
            if (cur.Status == desired.Status) continue;
            if (cur.Status == 'Completed' || cur.Status == 'Closed') continue;
            toUpdate.add(desired);
        }
        if (!toUpdate.isEmpty()) update toUpdate; // fires WorkOrderCaseSync -> Case
    }

    /**
     * Candidate-engine scheduling (NO ES&O optimizer). Uses FSL.AppointmentBookingService.GetSlots
     * — which works on the base managed package — to find a real available window honoring operating
     * hours + work rules + existing appointments, then books the best one and assigns a territory
     * resource. Replaces FSL.ScheduleService.schedule() (the optimizer), which throws "Schedule
     * optimization incomplete" until ES&O is provisioned. Returns true if it booked the SA.
     */
    public static Boolean candidateSchedule(Id saId) {
        List<ServiceAppointment> sas = [
            SELECT Id, Status, ServiceTerritoryId, ServiceTerritory.OperatingHoursId, Duration, DurationType
            FROM ServiceAppointment WHERE Id = :saId LIMIT 1
        ];
        if (sas.isEmpty()) return false;
        ServiceAppointment sa = sas[0];
        if (sa.Status != 'None' || sa.ServiceTerritoryId == null || sa.ServiceTerritory.OperatingHoursId == null) return false;

        List<FSL__Scheduling_Policy__c> pol = [SELECT Id FROM FSL__Scheduling_Policy__c WHERE Name = :policyName LIMIT 1];
        if (pol.isEmpty() || Test.isRunningTest()) return false;

        List<FSL.AppointmentBookingSlot> slots;
        try {
            slots = FSL.AppointmentBookingService.GetSlots(
                saId, pol[0].Id, sa.ServiceTerritory.OperatingHoursId,
                TimeZone.getTimeZone(UserInfo.getTimeZone().getID()), false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'candidateSchedule GetSlots failed for ' + saId + ': ' + e.getMessage());
            return false;
        }
        if (slots == null || slots.isEmpty()) return false;

        FSL.AppointmentBookingSlot best = slots[0];
        for (FSL.AppointmentBookingSlot s : slots) {
            if (s.Grade != null && (best.Grade == null || s.Grade > best.Grade)) best = s;
        }
        Integer durMin = 60;
        if (sa.Duration != null) durMin = (sa.DurationType == 'Hours') ? Integer.valueOf(sa.Duration * 60) : Integer.valueOf(sa.Duration);
        return bookSlot(saId, best.Interval.Start, durMin);
    }

    /**
     * Commit a specific time onto an SA: set the scheduled window + arrival window, assign an active
     * resource from the SA's territory, and move it to Scheduled. Used by candidateSchedule (auto) and
     * by the "confirm a chosen slot" action. No FSL callout — fully unit-testable.
     */
    public static Boolean bookSlot(Id saId, Datetime start, Integer durMin) {
        if (saId == null || start == null) return false;
        Integer dur = (durMin == null || durMin <= 0) ? 60 : durMin;
        List<ServiceAppointment> sas = [SELECT Id, ServiceTerritoryId FROM ServiceAppointment WHERE Id = :saId LIMIT 1];
        if (sas.isEmpty()) return false;

        update new ServiceAppointment(Id = saId, SchedStartTime = start, SchedEndTime = start.addMinutes(dur),
            ArrivalWindowStartTime = start, ArrivalWindowEndTime = start.addHours(2));

        if (sas[0].ServiceTerritoryId == null) return false;
        List<ServiceTerritoryMember> m = [
            SELECT ServiceResourceId FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :sas[0].ServiceTerritoryId AND ServiceResource.IsActive = true
            ORDER BY CreatedDate ASC LIMIT 1
        ];
        if (m.isEmpty()) return false;
        insert new AssignedResource(ServiceAppointmentId = saId, ServiceResourceId = m[0].ServiceResourceId);
        update new ServiceAppointment(Id = saId, Status = 'Scheduled');
        return true;
    }

    /**
     * REAL available arrival windows for a (settled) appointment, via the candidate engine —
     * each FSL availability interval sliced into AM/PM windows. Empty if not schedulable / on error.
     */
    public static List<FieldServiceSlots.Slot> realSlots(Id saId) {
        List<FieldServiceSlots.Slot> out = new List<FieldServiceSlots.Slot>();
        if (saId == null) return out;
        List<ServiceAppointment> sas = [
            SELECT ServiceTerritoryId, ServiceTerritory.OperatingHoursId
            FROM ServiceAppointment WHERE Id = :saId LIMIT 1
        ];
        if (sas.isEmpty() || sas[0].ServiceTerritoryId == null || sas[0].ServiceTerritory.OperatingHoursId == null) return out;
        List<FSL__Scheduling_Policy__c> pol = [SELECT Id FROM FSL__Scheduling_Policy__c WHERE Name = :policyName LIMIT 1];
        if (pol.isEmpty() || Test.isRunningTest()) return out;
        try {
            List<FSL.AppointmentBookingSlot> raw = FSL.AppointmentBookingService.GetSlots(
                saId, pol[0].Id, sas[0].ServiceTerritory.OperatingHoursId,
                TimeZone.getTimeZone(UserInfo.getTimeZone().getID()), false);
            for (FSL.AppointmentBookingSlot s : raw) {
                out.addAll(FieldServiceSlots.sliceInterval(s.Interval.Start, s.Interval.Finish));
                if (out.size() >= 8) break;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'realSlots failed for ' + saId + ': ' + e.getMessage());
        }
        return out;
    }

    /** Chained Queueable — books one SA per execution via the candidate engine (callout + DML). */
    public class AutoScheduleQueueable implements Queueable, Database.AllowsCallouts {
        List<Id> ids;
        public AutoScheduleQueueable(List<Id> ids) { this.ids = ids; }
        public void execute(QueueableContext ctx) {
            if (ids == null || ids.isEmpty()) return;
            Id saId = ids.remove(0);
            if (!skipSchedule && !Test.isRunningTest()) {
                try {
                    candidateSchedule(saId);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'FieldServiceAutopilot schedule failed for ' + saId + ': ' + e.getMessage());
                }
            }
            if (!ids.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new AutoScheduleQueueable(ids));
            }
        }
    }
}
