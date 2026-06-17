/** Agent action: renew a subscription for another term. */
public with sharing class SubRenew {
    public class Request {
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Renewal term in months (default 12)') public Decimal termMonths;
    }
    @InvocableMethod(label='Renew Subscription' description='Extends a subscription for another term.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            try {
                Asset a = SubscriptionConciergeService.resolveSubscription(r.subscriptionId, r.email);
                if (a == null) { res.success = false; res.summary = 'I couldn\'t find that subscription.'; out.add(res); continue; }
                Integer months = (r.termMonths == null || r.termMonths <= 0) ? 12 : r.termMonths.intValue();
                Date base = (a.UsageEndDate == null || a.UsageEndDate < Date.today()) ? Date.today() : a.UsageEndDate;
                a.UsageEndDate = base.addMonths(months);
                a.Status = 'Installed';
                update a;
                res.success = true; res.subscriptionId = a.Id;
                res.summary = 'Renewed! Your ' + a.Name + ' is now active through ' + SubscriptionConciergeService.dt(a.UsageEndDate) + '.';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t renew the subscription: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
