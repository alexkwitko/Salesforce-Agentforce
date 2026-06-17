/** Agent action: provision a new subscription (creates an Asset). */
public with sharing class SubProvision {
    public class Request {
        @InvocableVariable(label='Account Id') public String accountId;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Product Code' required=true) public String productCode;
        @InvocableVariable(label='Quantity (seats)') public Decimal quantity;
    }
    @InvocableMethod(label='Provision Subscription' description='Sets a customer up with a new subscription to a product.')
    public static List<SubscriptionConciergeService.Result> run(List<Request> reqs) {
        List<SubscriptionConciergeService.Result> out = new List<SubscriptionConciergeService.Result>();
        for (Request r : reqs) {
            SubscriptionConciergeService.Result res = new SubscriptionConciergeService.Result();
            try {
                Id acct = SubscriptionConciergeService.resolveAccount(r.accountId, r.email);
                if (acct == null) { res.success = false; res.summary = 'No matching account found.'; out.add(res); continue; }
                Decimal qty = (r.quantity == null || r.quantity <= 0) ? 1 : r.quantity;
                PricebookEntry pbe = [
                    SELECT Product2Id, Product2.Name, UnitPrice
                    FROM PricebookEntry
                    WHERE Product2.ProductCode = :r.productCode AND IsActive = true
                          AND Pricebook2.IsStandard = true AND ProductSellingModelId != null
                    ORDER BY ProductSellingModel.SellingModelType LIMIT 1
                ];
                Asset a = new Asset(
                    Name = pbe.Product2.Name, AccountId = acct, Product2Id = pbe.Product2Id,
                    Quantity = qty, Price = pbe.UnitPrice, Status = 'Installed',
                    InstallDate = Date.today(), UsageEndDate = Date.today().addYears(1)
                );
                insert a;
                res.success = true; res.subscriptionId = a.Id;
                res.summary = 'You\'re all set! I\'ve started your ' + pbe.Product2.Name + ' subscription — '
                    + qty.intValue() + ' @ ' + SubscriptionConciergeService.money(pbe.UnitPrice)
                    + ', renewing ' + SubscriptionConciergeService.dt(a.UsageEndDate) + '.';
            } catch (QueryException qe) {
                res.success = false; res.summary = 'I couldn\'t find a subscription product with code "' + r.productCode + '".';
            } catch (Exception e) {
                res.success = false; res.summary = 'Something went wrong starting the subscription: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
