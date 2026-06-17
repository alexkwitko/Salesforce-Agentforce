/** Agent action: review the book of subscriptions coming up for renewal. */
public with sharing class RenewalGetBook {
    public class Request {
        @InvocableVariable(label='Days ahead (default 60)') public Decimal daysAhead;
    }
    public class Response {
        @InvocableVariable(label='Count') public Integer count;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }
    @InvocableMethod(label='Get Renewal Book' description='Lists active subscriptions coming up for renewal within N days, each with churn risk and a recommended next-best action.')
    public static List<Response> run(List<Request> reqs) {
        List<Response> out = new List<Response>();
        for (Request r : reqs) {
            Response res = new Response();
            Integer days = (r.daysAhead == null || r.daysAhead <= 0) ? 60 : r.daysAhead.intValue();
            Date cutoff = Date.today().addDays(days);
            List<Asset> subs = [
                SELECT Account.Name, Account.Churn_Risk_Tier__c, Account.Churn_Score__c, Quantity, UsageEndDate
                FROM Asset
                WHERE Status = 'Installed' AND Product2.Family = 'Subscription'
                      AND UsageEndDate != null AND UsageEndDate <= :cutoff
                ORDER BY Account.Churn_Risk_Tier__c, UsageEndDate
            ];
            res.count = subs.size();
            if (subs.isEmpty()) {
                res.summary = 'No subscriptions are due for renewal in the next ' + days + ' days.';
                out.add(res); continue;
            }
            List<String> lines = new List<String>();
            for (Asset a : subs) {
                Integer d = Date.today().daysBetween(a.UsageEndDate);
                String tier = a.Account.Churn_Risk_Tier__c;
                Integer qty = (a.Quantity == null ? 0 : a.Quantity.intValue());
                lines.add('• ' + a.Account.Name + ' — ' + qty + ' bags, renews in ' + d + ' days (churn tier ' + tier + '). → '
                    + RenewalBookService.recommend(tier, a.Quantity));
            }
            res.summary = subs.size() + ' subscription(s) due in the next ' + days + ' days:\n' + String.join(lines, '\n');
            out.add(res);
        }
        return out;
    }
}
