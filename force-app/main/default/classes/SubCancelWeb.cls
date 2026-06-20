/**
 * SubCancelWeb — identity-gated web wrapper over SubCancel. Verified caller + ownership-scoped subscription.
 */
public with sharing class SubCancelWeb {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
    }
    @InvocableMethod(label='Cancel Subscription (Web)' description='Verified web shopper only: cancels their own subscription.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            String gate = SubscriptionConciergeService.gate(r.email, r.verifiedEmail);
            if (gate != null) { res.success = false; res.summary = gate; out.add(res); continue; }
            Asset owned = SubscriptionConciergeService.resolveOwnedSubscription(r.subscriptionId, r.email);
            if (owned == null) { res.success = false; res.summary = 'I couldn\'t find that subscription on your account.'; out.add(res); continue; }
            SubCancel.Request req = new SubCancel.Request();
            req.email = r.email; req.subscriptionId = owned.Id;
            out.addAll(SubCancel.run(new List<SubCancel.Request>{ req }));
        }
        return out;
    }
}
