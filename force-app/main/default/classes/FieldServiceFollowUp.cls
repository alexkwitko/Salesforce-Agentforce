/**
 * FieldServiceFollowUp — add ANOTHER Service Appointment under the same Work Order
 * for a return trip (a part was needed, or a new issue was found on site).
 * The original WO stays OPEN; the new SA goes through the normal dispatch autopilot.
 * Callable by the agent and by the technician (mobile quick action).
 */
public with sharing class FieldServiceFollowUp {

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String summary;
        @InvocableVariable public Id serviceAppointmentId;
    }

    public class Request {
        @InvocableVariable(label='Work Order Id' required=true) public Id workOrderId;
        @InvocableVariable(label='Reason (Parts / Additional Issue)') public String reason;
        @InvocableVariable(label='Preferred date (YYYY-MM-DD)') public String preferredDate;
        @InvocableVariable(label='Notes') public String notes;
    }

    @InvocableMethod(label='Create Follow-up Visit'
        description='Adds another Service Appointment under the same Work Order for a return trip (parts needed / additional issue) and keeps the Work Order open.')
    public static List<Result> run(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            out.add(create(r.workOrderId, r.reason, r.preferredDate, r.notes));
        }
        return out;
    }

    // Reusable core (also called by FieldPartsService when stock is short).
    public static Result create(Id workOrderId, String reason, String preferredDate, String notes) {
        Result res = new Result(); res.success = false;
        if (workOrderId == null) { res.summary = 'A work order is required.'; return res; }
        List<WorkOrder> wos = [SELECT Id, Subject, Status FROM WorkOrder WHERE Id = :workOrderId LIMIT 1];
        if (wos.isEmpty()) { res.summary = 'Work order not found.'; return res; }

        String visitReason = (reason == 'Return - Additional Issue') ? 'Return - Additional Issue' : 'Return - Parts Needed';
        Date d = FsMaintenanceService.parseDate(preferredDate);
        Datetime earliest = Datetime.newInstance(d, Time.newInstance(9, 0, 0, 0));

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = workOrderId,
            Subject = visitReason + (String.isBlank(notes) ? '' : (': ' + notes)),
            EarliestStartTime = earliest, DueDate = earliest.addDays(7),
            ArrivalWindowStartTime = earliest, ArrivalWindowEndTime = earliest.addHours(4),
            Visit_Reason__c = visitReason, Status = 'None'
        );
        insert sa; // ServiceAppointmentAutopilot assigns territory + schedules

        // Keep the WO open while the return visit is pending.
        String woStatus = (visitReason == 'Return - Parts Needed') ? 'On Hold' : 'In Progress';
        if (wos[0].Status != 'Completed' && wos[0].Status != 'Closed') {
            update new WorkOrder(Id = workOrderId, Status = woStatus); // -> Case Working
        }

        res.success = true;
        res.serviceAppointmentId = sa.Id;
        res.summary = 'Follow-up visit created (' + visitReason + ') around '
            + FsMaintenanceService.fmt(earliest) + '. The work order stays open until it\'s resolved.';
        return res;
    }
}
