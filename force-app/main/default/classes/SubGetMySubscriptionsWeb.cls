/**
 * SubGetMySubscriptionsWeb — identity-gated web wrapper over SubGetMySubscriptions.
 * Customer-web (Kwitko_Concierge_Web) calls THIS; it requires a verified caller and scopes strictly to the
 * verified email's account. The un-gated SubGetMySubscriptions stays for the trusted internal copilot.
 */
public with sharing class SubGetMySubscriptionsWeb {
    public class Request {
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
    }
    @InvocableMethod(label='Get My Subscriptions (Web)' description='Verified web shopper only: lists their own active subscriptions.')
    public static List<SubGetMySubscriptions.Response> run(List<Request> reqs) {
        List<SubGetMySubscriptions.Response> out = new List<SubGetMySubscriptions.Response>();
        for (Request r : reqs) {
            String gate = SubscriptionConciergeService.gate(r.email, r.verifiedEmail);
            if (gate != null) {
                SubGetMySubscriptions.Response res = new SubGetMySubscriptions.Response();
                res.hasSubscriptions = false; res.summary = gate;
                out.add(res); continue;
            }
            SubGetMySubscriptions.Request req = new SubGetMySubscriptions.Request();
            req.email = r.email;            // scope to the verified email's account
            req.accountId = null;           // never trust a caller-supplied accountId on the web
            out.addAll(SubGetMySubscriptions.run(new List<SubGetMySubscriptions.Request>{ req }));
        }
        return out;
    }
}
