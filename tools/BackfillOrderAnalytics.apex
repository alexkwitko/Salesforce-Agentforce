/**
 * Backfill Order_Analytics__c (the denormalized order+demographics object that feeds the
 * Order_Patterns_by_Demographics Calculated Insight). It was 0 rows, so the CI computed 0.
 * Source data exists: 390 Orders, Account.Gender__c + PersonBirthdate + BillingState (~150/176),
 * Product2.Family as category. Idempotent: wipes + rebuilds.
 */
List<Order_Analytics__c> existing = [SELECT Id FROM Order_Analytics__c LIMIT 50000];
if (!existing.isEmpty()) { delete existing; }

// Dominant product Family per order (most line items)
Map<Id, Map<String,Integer>> catCount = new Map<Id, Map<String,Integer>>();
for (OrderItem oi : [
        SELECT OrderId, Quantity, Product2.Family
        FROM OrderItem WHERE Order.AccountId != null]) {
    String fam = (oi.Product2 != null && oi.Product2.Family != null) ? oi.Product2.Family : 'Uncategorized';
    if (!catCount.containsKey(oi.OrderId)) catCount.put(oi.OrderId, new Map<String,Integer>());
    Map<String,Integer> m = catCount.get(oi.OrderId);
    Integer q = (oi.Quantity == null) ? 1 : Integer.valueOf(oi.Quantity);
    m.put(fam, (m.containsKey(fam) ? m.get(fam) : 0) + q);
}

Date today = Date.today();
List<Order_Analytics__c> rows = new List<Order_Analytics__c>();
for (Order o : [
        SELECT Id, AccountId, TotalAmount, EffectiveDate,
               Account.Gender__c, Account.PersonBirthdate,
               Account.BillingStateCode, Account.ShippingStateCode, Account.PersonMailingStateCode,
               Account.BillingState, Account.ShippingState, Account.PersonMailingState
        FROM Order WHERE AccountId != null]) {

    // age group
    String ageGroup = 'Unknown';
    if (o.Account.PersonBirthdate != null) {
        Integer age = o.Account.PersonBirthdate.daysBetween(today) / 365;
        if (age < 25) ageGroup = '18-24';
        else if (age < 35) ageGroup = '25-34';
        else if (age < 45) ageGroup = '35-44';
        else if (age < 55) ageGroup = '45-54';
        else if (age < 65) ageGroup = '55-64';
        else ageGroup = '65+';
    }
    // state code (2-letter; field max length = 10). prefer billing, then mailing, then shipping.
    String st = o.Account.BillingStateCode != null ? o.Account.BillingStateCode
              : (o.Account.PersonMailingStateCode != null ? o.Account.PersonMailingStateCode
              : (o.Account.ShippingStateCode != null ? o.Account.ShippingStateCode
              : (o.Account.BillingState != null ? o.Account.BillingState : null)));
    if (st != null && st.length() > 10) st = st.substring(0, 10);
    // dominant category
    String cat = 'Uncategorized';
    if (catCount.containsKey(o.Id)) {
        Integer best = -1;
        for (String k : catCount.get(o.Id).keySet()) {
            if (catCount.get(o.Id).get(k) > best) { best = catCount.get(o.Id).get(k); cat = k; }
        }
    }
    rows.add(new Order_Analytics__c(
        Account__c       = o.AccountId,
        Order__c         = o.Id,
        Gender__c        = o.Account.Gender__c != null ? o.Account.Gender__c : 'Unknown',
        Age_Group__c     = ageGroup,
        State__c         = (st != null ? st : 'Unknown'),
        Order_Amount__c  = o.TotalAmount,
        Order_Date__c    = o.EffectiveDate,
        Product_Category__c = cat,
        Email_Consent__c = true
    ));
}
insert rows;
System.debug('Inserted Order_Analytics__c rows: ' + rows.size());
System.debug('Sample: ' + (rows.isEmpty() ? 'none' : JSON.serialize(rows[0])));
