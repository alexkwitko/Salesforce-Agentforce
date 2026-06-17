/** Agent action: renew a named account's active subscription (fires the RLM↔FSL coupling). */
public with sharing class RenewalRenew {
    public class Request {
        @InvocableVariable(label='Account Name' required=true) public String accountName;
        @InvocableVariable(label='Renewal term months (default 12)') public Decimal termMonths;
    }
    @InvocableMethod(label='Renew Account Subscription' description='Renews the named account active subscription for another term; linked maintenance coverage extends automatically.')
    public static List<RenewalBookService.Result> run(List<Request> reqs) {
        List<RenewalBookService.Result> out = new List<RenewalBookService.Result>();
        for (Request r : reqs) {
            RenewalBookService.Result res = new RenewalBookService.Result();
            Account acc = RenewalBookService.resolveAccountByName(r.accountName);
            if (acc == null) { res.success = false; res.summary = 'No account found matching "' + r.accountName + '".'; out.add(res); continue; }
            Asset a = RenewalBookService.latestActiveSub(acc.Id);
            if (a == null) { res.success = false; res.summary = acc.Name + ' has no active subscription to renew.'; out.add(res); continue; }
            Integer months = (r.termMonths == null || r.termMonths <= 0) ? 12 : r.termMonths.intValue();
            Date base = (a.UsageEndDate == null || a.UsageEndDate < Date.today()) ? Date.today() : a.UsageEndDate;
            a.UsageEndDate = base.addMonths(months);
            update a; // fires AssetSubscriptionLifecycle -> extends MaintenancePlan + ServiceContract
            res.success = true;
            res.summary = 'Renewed ' + acc.Name + ' for ' + months + ' months — active through ' + a.UsageEndDate.format()
                + '. Any linked maintenance coverage was extended automatically.';
            out.add(res);
        }
        return out;
    }
}
