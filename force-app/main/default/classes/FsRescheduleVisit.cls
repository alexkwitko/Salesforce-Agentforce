/** Agent action: reschedule the customer's soonest upcoming maintenance visit. */
public with sharing class FsRescheduleVisit {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='New date (YYYY-MM-DD)' required=true) public String newDate;
    }
    @InvocableMethod(label='Reschedule Maintenance Visit' description='Moves the customer next maintenance visit to a new preferred date.')
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
            if (sa == null) { res.success = false; res.summary = 'You don\'t have an upcoming visit to reschedule.'; out.add(res); continue; }
            Date d = FsMaintenanceService.parseDate(r.newDate);
            Datetime earliest = Datetime.newInstance(d, Time.newInstance(9, 0, 0, 0));
            sa.EarliestStartTime = earliest;
            sa.DueDate = earliest.addDays(7);
            sa.ArrivalWindowStartTime = earliest;
            sa.ArrivalWindowEndTime = earliest.addHours(4);
            sa.SchedStartTime = null; sa.SchedEndTime = null; // back to pending dispatch
            sa.Status = 'None';
            update sa;
            res.success = true;
            res.summary = 'Done — I\'ve moved your maintenance visit to around ' + FsMaintenanceService.fmt(earliest)
                + '. Dispatch will reconfirm the exact time.';
            out.add(res);
        }
        return out;
    }
}
