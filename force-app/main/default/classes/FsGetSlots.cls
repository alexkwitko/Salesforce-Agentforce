/** Agent action: show the customer REAL available arrival windows for their maintenance visit. */
public with sharing class FsGetSlots {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Days to look ahead') public Decimal daysAhead;
    }
    @InvocableMethod(label='Get Visit Slots'
        description='Returns the REAL available maintenance arrival windows (from the scheduling engine) for the customer to choose from.')
    public static List<FsMaintenanceService.Result> run(List<Request> reqs) {
        List<FsMaintenanceService.Result> out = new List<FsMaintenanceService.Result>();
        for (Request r : reqs) {
            // Availability windows aren't PII — show them to guests too; booking is what's gated.
            FsMaintenanceService.Result res = new FsMaintenanceService.Result();
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) {
                res.success = false;
                res.summary = 'Tell me the account name or email on file and I\'ll pull available times.';
                out.add(res); continue;
            }
            // Find the customer's current maintenance appointment (settled, so the engine can grade it).
            Map<Id, WorkOrder> wos = new Map<Id, WorkOrder>([
                SELECT Id FROM WorkOrder WHERE AccountId = :acc.Id ORDER BY CreatedDate DESC LIMIT 10
            ]);
            List<ServiceAppointment> sas = wos.isEmpty() ? new List<ServiceAppointment>() : [
                SELECT Id FROM ServiceAppointment
                WHERE ParentRecordId IN :wos.keySet() AND Status IN ('None', 'Scheduled')
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (sas.isEmpty()) {
                res.success = true;
                res.summary = 'I don\'t see an open maintenance visit to pull times for yet — want me to book one? I\'ll reserve the soonest available slot.';
                out.add(res); continue;
            }
            List<FieldServiceSlots.Slot> slots = FieldServiceAutopilot.realSlots(sas[0].Id);
            res.success = true;
            res.summary = slots.isEmpty()
                ? 'I couldn\'t find open windows in the next stretch — our dispatch team will confirm the best time for your visit.'
                : FieldServiceSlots.summarize(slots);
            out.add(res);
        }
        return out;
    }
}
