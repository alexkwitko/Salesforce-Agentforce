// Backfill Order_Analytics__c from real Orders + Account demographics.
// Idempotent: keyed by Order__c (delete existing analytics rows first, then rebuild).
List<Order_Analytics__c> existing = [SELECT Id FROM Order_Analytics__c LIMIT 50000];
if (!existing.isEmpty()) { delete existing; }

Map<Id, Account> accts = new Map<Id, Account>(
    [SELECT Id, Gender__c, Email_Consent__c, BillingState, PersonMailingState
     FROM Account]
);

// primary product category per order (first order item's product family/category)
Map<Id, String> orderCategory = new Map<Id, String>();
for (OrderItem oi : [SELECT OrderId, Product2.Family FROM OrderItem ORDER BY OrderId, CreatedDate]) {
    if (!orderCategory.containsKey(oi.OrderId) && oi.Product2 != null && oi.Product2.Family != null) {
        orderCategory.put(oi.OrderId, oi.Product2.Family);
    }
}

List<Order_Analytics__c> rows = new List<Order_Analytics__c>();
for (Order o : [SELECT Id, AccountId, TotalAmount, EffectiveDate FROM Order]) {
    Account a = accts.get(o.AccountId);
    String st = null;
    if (a != null) { st = (a.BillingState != null) ? a.BillingState : a.PersonMailingState; }
    if (st != null && st.length() > 10) { st = st.substring(0, 10); }
    rows.add(new Order_Analytics__c(
        Order__c          = o.Id,
        Account__c        = o.AccountId,
        Order_Amount__c   = (o.TotalAmount != null ? o.TotalAmount : 0),
        Order_Date__c     = o.EffectiveDate,
        Gender__c         = (a != null ? a.Gender__c : null),
        Email_Consent__c  = (a != null ? a.Email_Consent__c : null),
        State__c          = st,
        Product_Category__c = orderCategory.get(o.Id)
    ));
}
insert rows;
System.debug('INSERTED Order_Analytics__c rows = ' + rows.size());
System.debug('TOTAL now = ' + [SELECT COUNT() FROM Order_Analytics__c]);
