/** Agent action: list a customer's active subscriptions. */
public with sharing class SubGetMySubscriptions {
    public class Request {
        @InvocableVariable(label='Account Id') public String accountId;
        @InvocableVariable(label='Account Email') public String email;
    }
    public class Response {
        @InvocableVariable(label='Has subscriptions') public Boolean hasSubscriptions;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }
    @InvocableMethod(label='Get My Subscriptions' description='Lists the subscriptions a customer currently owns.')
    public static List<Response> run(List<Request> reqs) {
        List<Response> out = new List<Response>();
        for (Request r : reqs) {
            Response res = new Response();
            Id acct = SubscriptionConciergeService.resolveAccount(r.accountId, r.email);
            if (acct == null) {
                res.hasSubscriptions = false;
                res.summary = 'I couldn\'t find an account for that customer.';
                out.add(res); continue;
            }
            List<Asset> subs = [
                SELECT Name, Product2.Name, Quantity, Price, Status, UsageEndDate
                FROM Asset WHERE AccountId = :acct AND Status != 'Obsolete'
                ORDER BY InstallDate DESC
            ];
            if (subs.isEmpty()) {
                res.hasSubscriptions = false;
                res.summary = 'You don\'t have any active subscriptions right now.';
            } else {
                res.hasSubscriptions = true;
                List<String> lines = new List<String>();
                for (Asset a : subs) {
                    String prod = a.Product2 != null ? a.Product2.Name : a.Name;
                    Integer q = (a.Quantity == null ? 0 : a.Quantity.intValue());
                    lines.add('• ' + prod + ' — qty ' + q + ' @ ' + SubscriptionConciergeService.money(a.Price)
                        + ', renews ' + SubscriptionConciergeService.dt(a.UsageEndDate) + ' (' + a.Status + ')');
                }
                res.summary = 'Here\'s what you\'re subscribed to:\n' + String.join(lines, '\n');
            }
            out.add(res);
        }
        return out;
    }
}
