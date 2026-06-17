/** Agent action: list the customer's upcoming maintenance visits + status/ETA. */
public with sharing class FsGetVisits {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
    }
    public class Response {
        @InvocableVariable(label='Has visits') public Boolean hasVisits;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }
    @InvocableMethod(label='Get Maintenance Visits' description='Lists the customer upcoming/scheduled maintenance visits with status and expected timing.')
    public static List<Response> run(List<Request> reqs) {
        List<Response> out = new List<Response>();
        for (Request r : reqs) {
            Response res = new Response();
            if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
                res.hasVisits = false; res.summary = IdentityService.signInMessage(); out.add(res); continue;
            }
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) { res.hasVisits = false; res.summary = 'I couldn\'t find that account.'; out.add(res); continue; }
            List<ServiceAppointment> sas = [
                SELECT Subject, Status, EarliestStartTime, SchedStartTime, ArrivalWindowStartTime, ArrivalWindowEndTime
                FROM ServiceAppointment
                WHERE AccountId = :acc.Id AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
                ORDER BY EarliestStartTime ASC NULLS LAST
            ];
            if (sas.isEmpty()) {
                res.hasVisits = false;
                res.summary = 'You don\'t have any upcoming maintenance visits scheduled. Want me to book one?';
            } else {
                res.hasVisits = true;
                List<String> lines = new List<String>();
                for (ServiceAppointment sa : sas) {
                    Datetime visitTime = sa.SchedStartTime != null ? sa.SchedStartTime : sa.EarliestStartTime;
                    String eta = sa.SchedStartTime != null ? 'scheduled for ' + FsMaintenanceService.fmt(visitTime)
                                                           : 'requested for ' + FsMaintenanceService.fmt(visitTime) + ' (awaiting dispatch)';
                    lines.add('• ' + (sa.Subject == null ? 'Maintenance visit' : sa.Subject) + ' — ' + eta + ' [' + sa.Status + ']');
                }
                res.summary = 'Here are your upcoming visits:\n' + String.join(lines, '\n');
            }
            out.add(res);
        }
        return out;
    }
}
