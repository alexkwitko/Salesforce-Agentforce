/**
 * FieldServiceCaseSync — keeps the service Case in lockstep with its Work Order.
 *   WO In Progress / On Hold   -> Case Working
 *   WO Completed / Closed      -> Case Closed
 *   WO Cannot Complete         -> Case Escalated
 * Called from the WorkOrderCaseSync trigger (after update / after insert).
 */
public with sharing class FieldServiceCaseSync {

    // Map a Work Order status to the Case status it should drive (null = leave Case alone).
    public static String caseStatusFor(String woStatus) {
        if (woStatus == null) return null;
        switch on woStatus {
            when 'In Progress', 'On Hold' { return 'Working'; }
            when 'Completed', 'Closed', 'Canceled' { return 'Closed'; }
            when 'Cannot Complete' { return 'Escalated'; }
            when else { return null; } // 'New' etc. — don't override
        }
    }

    public static void syncFromWorkOrders(List<WorkOrder> news, Map<Id, WorkOrder> oldMap) {
        Map<Id, String> desiredByCase = new Map<Id, String>();
        for (WorkOrder wo : news) {
            if (wo.CaseId == null) continue;
            // only act when status changed (or on insert when oldMap is null)
            String oldStatus = (oldMap == null) ? null : oldMap.get(wo.Id).Status;
            if (oldMap != null && oldStatus == wo.Status) continue;
            String target = caseStatusFor(wo.Status);
            if (target == null) continue;
            desiredByCase.put(wo.CaseId, target); // last WO wins if many on one case
        }
        if (desiredByCase.isEmpty()) return;

        List<Case> updates = new List<Case>();
        for (Case c : [SELECT Id, Status, Resolution__c FROM Case WHERE Id IN :desiredByCase.keySet()]) {
            String target = desiredByCase.get(c.Id);
            if (c.Status == target) continue;
            Case upd = new Case(Id = c.Id, Status = target);
            // Org rule: a Case can't close without a Resolution. Stamp one if empty.
            if (target == 'Closed' && String.isBlank(c.Resolution__c)) {
                upd.Resolution__c = 'Resolved via field service — work order completed.';
            }
            updates.add(upd);
        }
        if (!updates.isEmpty()) update updates;
    }
}
