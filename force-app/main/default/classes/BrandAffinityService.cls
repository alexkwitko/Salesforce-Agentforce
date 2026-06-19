/**
 * BrandAffinityService — rolls each Account's distinct order brands onto the Account
 * (Brands_Purchased__c + Is_Multi_Brand__c) so the unified profile + the Concierge can
 * recognize cross-brand customers (a person who buys from BOTH Kwitko Coffee and Bean & Brew).
 * Brand source = Order.Brand__c (stamped by OrderBrandStamp from product family).
 * Runs in class context so Order.Brand__c is readable (it is FLS-hidden to ad-hoc/anon queries).
 */
public without sharing class BrandAffinityService implements Schedulable {
    public void execute(SchedulableContext sc) { run(); }

    public static Integer run() {
        Map<Id, Set<String>> brandsByAcct = new Map<Id, Set<String>>();
        for (Order o : [SELECT AccountId, Brand__c FROM Order WHERE AccountId != null AND Brand__c != null]) {
            if (!brandsByAcct.containsKey(o.AccountId)) brandsByAcct.put(o.AccountId, new Set<String>());
            brandsByAcct.get(o.AccountId).add(o.Brand__c);
        }
        List<Account> ups = new List<Account>();
        for (Id acctId : brandsByAcct.keySet()) {
            List<String> brands = new List<String>(brandsByAcct.get(acctId));
            brands.sort();
            String joined = String.join(brands, '; ');
            ups.add(new Account(Id = acctId,
                Brands_Purchased__c = joined.length() > 255 ? joined.substring(0, 255) : joined,
                Is_Multi_Brand__c = (brands.size() > 1)));
        }
        if (!ups.isEmpty()) update ups;
        return ups.size();
    }
}
