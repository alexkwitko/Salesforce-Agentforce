/** Agent action: cancel the customer's soonest upcoming maintenance visit. */
public with sharing class FsCancelVisit {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
    }
    @InvocableMethod(label='Cancel Maintenance Visit' description='Cancels the customer next upcoming maintenance visit. Confirm intent before calling.')
    public static List<FsMaintenanceService.Result> run(List<Request> reqs) {
        List<FsMaintenanceService.Result> out = new List<FsMaintenanceService.Result>();
        for (Request r : reqs) {
            FsMaintenanceService.Result res = new FsMaintenanceService.Result();
            if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
                res.success = false; res.summary = IdentityService.signInMessage(); out.add(res); continue;
            }
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) { res.success = false; res.summary = 'I couldn\'t find that account.'; out.add(res); continue; }
            ServiceAppointment sa = FsMaintenanceService.soonestUpcoming(acc.Id);
            if (sa == null) { res.success = false; res.summary = 'You don\'t have an upcoming visit to cancel.'; out.add(res); continue; }
            Datetime visitTime = sa.SchedStartTime != null ? sa.SchedStartTime : sa.EarliestStartTime;
            sa.Status = 'Canceled';
            update sa;
            res.success = true;
            res.summary = 'Your maintenance visit (' + FsMaintenanceService.fmt(visitTime) + ') has been cancelled. Let me know if you\'d like to rebook.';
            out.add(res);
        }
        return out;
    }
}
