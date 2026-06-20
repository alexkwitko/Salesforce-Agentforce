/**
 * SubProvisionWeb — identity-gated web wrapper over SubProvision. Verified caller only; provisions on the
 * verified email's account (never a caller-supplied accountId).
 */
public with sharing class SubProvisionWeb {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Product Code' required=true) public String productCode;
        @InvocableVariable(label='Quantity (seats)') public Decimal quantity;
    }
    @InvocableMethod(label='Provision Subscription (Web)' description='Verified web shopper only: starts a new subscription on their own account.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            String gate = SubscriptionConciergeService.gate(r.email, r.verifiedEmail);
            if (gate != null) {
                SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
                res.success = false; res.summary = gate;
                out.add(res); continue;
            }
            SubProvision.Request req = new SubProvision.Request();
            req.email = r.email; req.accountId = null; req.productCode = r.productCode; req.quantity = r.quantity;
            out.addAll(SubProvision.run(new List<SubProvision.Request>{ req }));
        }
        return out;
    }
}
