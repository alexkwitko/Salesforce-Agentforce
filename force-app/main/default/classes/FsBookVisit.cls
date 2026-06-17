/** Agent action: book a maintenance visit (creates WorkOrder + ServiceAppointment). */
public with sharing class FsBookVisit {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Preferred date (YYYY-MM-DD)') public String preferredDate;
    }
    @InvocableMethod(label='Book Maintenance Visit' description='Books a maintenance visit for the customer on or around a preferred date (creates a work order + service appointment, pending dispatch).')
    public static List<FsMaintenanceService.Result> run(List<Request> reqs) {
        List<FsMaintenanceService.Result> out = new List<FsMaintenanceService.Result>();
        for (Request r : reqs) {
            FsMaintenanceService.Result res = new FsMaintenanceService.Result();
            if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
                res.success = false; res.summary = IdentityService.signInMessage(); out.add(res); continue;
            }
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) { res.success = false; res.summary = 'I couldn\'t find that account.'; out.add(res); continue; }

            Date d = FsMaintenanceService.parseDate(r.preferredDate);
            // Covered asset + active contract (optional links)
            List<Asset> assets = [SELECT Id, Name FROM Asset WHERE AccountId = :acc.Id AND Status = 'Installed' LIMIT 1];
            List<ServiceContract> scs = [SELECT Id FROM ServiceContract WHERE AccountId = :acc.Id AND EndDate >= :Date.today() ORDER BY EndDate DESC LIMIT 1];

            WorkOrder wo = new WorkOrder(
                AccountId = acc.Id, Subject = 'Maintenance visit', Status = 'New',
                AssetId = assets.isEmpty() ? null : assets[0].Id,
                ServiceContractId = scs.isEmpty() ? null : scs[0].Id
            );
            insert wo;

            Datetime earliest = Datetime.newInstance(d, Time.newInstance(9, 0, 0, 0));
            ServiceAppointment sa = new ServiceAppointment(
                ParentRecordId = wo.Id, Subject = 'Maintenance visit',
                EarliestStartTime = earliest, DueDate = earliest.addDays(7),
                ArrivalWindowStartTime = earliest, ArrivalWindowEndTime = earliest.addHours(4),
                Status = 'None'
            );
            insert sa;

            res.success = true;
            res.summary = 'Booked! I\'ve requested a maintenance visit for ' + acc.Name + ' around '
                + FsMaintenanceService.fmt(earliest) + ' (morning window). Our dispatch team will confirm the exact time.';
            out.add(res);
        }
        return out;
    }
}
