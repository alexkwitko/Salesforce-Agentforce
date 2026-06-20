/**
 * SubAmendWeb — identity-gated web wrapper over SubAmend. Verified caller only, and the target subscription
 * MUST belong to the verified email's account (closes the IDOR hole). Delegates the actual change to SubAmend.
 */
public with sharing class SubAmendWeb {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
        @InvocableVariable(label='New Quantity (seats)' required=true) public Decimal newQuantity;
    }
    @InvocableMethod(label='Amend Subscription (Web)' description='Verified web shopper only: changes seats on their own subscription.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            String gate = SubscriptionConciergeService.gate(r.email, r.verifiedEmail);
            if (gate != null) { res.success = false; res.summary = gate; out.add(res); continue; }
            Asset owned = SubscriptionConciergeService.resolveOwnedSubscription(r.subscriptionId, r.email);
            if (owned == null) { res.success = false; res.summary = 'I couldn\'t find that subscription on your account.'; out.add(res); continue; }
            SubAmend.Request req = new SubAmend.Request();
            req.email = r.email; req.subscriptionId = owned.Id; req.newQuantity = r.newQuantity;
            out.addAll(SubAmend.run(new List<SubAmend.Request>{ req }));
        }
        return out;
    }
}
