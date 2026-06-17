/** Agent action: tell the customer what maintenance coverage they have. */
public with sharing class FsGetCoverage {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
    }
    public class Response {
        @InvocableVariable(label='Covered') public Boolean covered;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }
    @InvocableMethod(label='Get Maintenance Coverage' description='Tells the customer what equipment is covered and until when, based on their service contract.')
    public static List<Response> run(List<Request> reqs) {
        List<Response> out = new List<Response>();
        for (Request r : reqs) {
            Response res = new Response();
            if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
                res.covered = false; res.summary = IdentityService.signInMessage(); out.add(res); continue;
            }
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) { res.covered = false; res.summary = 'I couldn\'t find that account.'; out.add(res); continue; }
            List<ServiceContract> scs = [
                SELECT Name, StartDate, EndDate FROM ServiceContract
                WHERE AccountId = :acc.Id AND EndDate >= :Date.today() ORDER BY EndDate DESC
            ];
            List<Asset> assets = [SELECT Name FROM Asset WHERE AccountId = :acc.Id AND Status = 'Installed'];
            if (scs.isEmpty()) {
                res.covered = false;
                res.summary = acc.Name + ' has no active maintenance contract on file. Would you like info on our care plans?';
            } else {
                res.covered = true;
                ServiceContract sc = scs[0];
                String equip = assets.isEmpty() ? 'your equipment' : assets[0].Name;
                res.summary = 'You\'re covered under "' + sc.Name + '" through ' + sc.EndDate.format()
                    + ' for ' + equip + '. Maintenance visits are included.';
            }
            out.add(res);
        }
        return out;
    }
}
