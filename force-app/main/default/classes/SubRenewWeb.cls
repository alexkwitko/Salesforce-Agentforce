/**
 * SubRenewWeb — identity-gated web wrapper over SubRenew. Verified caller + ownership-scoped subscription.
 */
public with sharing class SubRenewWeb {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
        @InvocableVariable(label='Renewal term in months (default 12)') public Decimal termMonths;
    }
    @InvocableMethod(label='Renew Subscription (Web)' description='Verified web shopper only: renews their own subscription.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            String gate = SubscriptionConciergeService.gate(r.email, r.verifiedEmail);
            if (gate != null) { res.success = false; res.summary = gate; out.add(res); continue; }
            Asset owned = SubscriptionConciergeService.resolveOwnedSubscription(r.subscriptionId, r.email);
            if (owned == null) { res.success = false; res.summary = 'I couldn\'t find that subscription on your account.'; out.add(res); continue; }
            SubRenew.Request req = new SubRenew.Request();
            req.email = r.email; req.subscriptionId = owned.Id; req.termMonths = r.termMonths;
            out.addAll(SubRenew.run(new List<SubRenew.Request>{ req }));
        }
        return out;
    }
}
