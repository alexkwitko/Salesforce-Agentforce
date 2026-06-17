/** Agent action: amend (change seats on) a subscription. */
public with sharing class SubAmend {
    public class Request {
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='New Quantity (seats)' required=true) public Decimal newQuantity;
    }
    @InvocableMethod(label='Amend Subscription' description='Changes the quantity/seats on an existing subscription (upgrade or downgrade).')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            try {
                Asset a = SubscriptionConciergeService.resolveSubscription(r.subscriptionId, r.email);
                if (a == null) { res.success = false; res.summary = 'I couldn\'t find that subscription.'; out.add(res); continue; }
                if (r.newQuantity == null || r.newQuantity <= 0) { res.success=false; res.summary='Please tell me the new number of seats.'; out.add(res); continue; }
                Decimal oldQty = a.Quantity == null ? 0 : a.Quantity;
                String verb = r.newQuantity > oldQty ? 'upgraded' : 'adjusted';
                a.Quantity = r.newQuantity;
                update a;
                res.success = true; res.subscriptionId = a.Id;
                res.summary = 'Done — I\'ve ' + verb + ' your ' + a.Name + ' from '
                    + oldQty.intValue() + ' to ' + r.newQuantity.intValue() + ' seats.';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t change the subscription: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
