/** Agent action: cancel a subscription. */
public with sharing class SubCancel {
    public class Request {
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
        @InvocableVariable(label='Account Email') public String email;
    }
    @InvocableMethod(label='Cancel Subscription' description='Cancels an active subscription.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            try {
                Asset a = SubscriptionConciergeService.resolveSubscription(r.subscriptionId, r.email);
                if (a == null) { res.success = false; res.summary = 'I couldn\'t find that subscription.'; out.add(res); continue; }
                a.Status = 'Obsolete';
                a.UsageEndDate = Date.today();
                update a;
                res.success = true; res.subscriptionId = a.Id;
                res.summary = 'I\'ve cancelled your ' + a.Name + ' subscription, effective today. Sorry to see you go!';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t cancel the subscription: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
