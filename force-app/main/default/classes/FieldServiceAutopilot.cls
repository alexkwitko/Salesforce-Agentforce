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

    /** Chained Queueable — schedules one SA per execution to respect callout/CPU limits. */
    public class AutoScheduleQueueable implements Queueable, Database.AllowsCallouts {
        List<Id> ids;
        public AutoScheduleQueueable(List<Id> ids) { this.ids = ids; }
        public void execute(QueueableContext ctx) {
            if (ids == null || ids.isEmpty()) return;
            Id saId = ids.remove(0);
            if (!skipSchedule && !Test.isRunningTest()) {
                try {
                    Id policyId = [SELECT Id FROM FSL__Scheduling_Policy__c WHERE Name = :policyName LIMIT 1].Id;
                    FSL.ScheduleService.schedule(policyId, saId);
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
