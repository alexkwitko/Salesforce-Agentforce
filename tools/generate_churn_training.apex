// Point-in-time churn training snapshots: features from orders BEFORE each ref date,
// label churned = NO order in the 60 days AFTER. All real history, no leakage.
Date[] refs = new Date[]{ Date.newInstance(2026,1,15), Date.newInstance(2026,2,1),
                          Date.newInstance(2026,3,1),  Date.newInstance(2026,4,1) };
delete [SELECT Id FROM Churn_Training__c];
List<Order> allOrders = [SELECT AccountId, EffectiveDate, TotalAmount FROM Order
                         WHERE AccountId != null AND EffectiveDate != null ORDER BY EffectiveDate];
List<Churn_Training__c> rows = new List<Churn_Training__c>();
for (Date ref : refs) {
    Map<Id, List<Order>> pre = new Map<Id, List<Order>>();
    Set<Id> boughtAfter = new Set<Id>();
    Date winEnd = ref.addDays(60);
    for (Order o : allOrders) {
        if (o.EffectiveDate < ref) {
            if (!pre.containsKey(o.AccountId)) pre.put(o.AccountId, new List<Order>());
            pre.get(o.AccountId).add(o);
        } else if (o.EffectiveDate < winEnd) {
            boughtAfter.add(o.AccountId);
        }
    }
    for (Id aid : pre.keySet()) {
        List<Order> os = pre.get(aid);
        Decimal total = 0; Integer last30 = 0;
        Date first = os[0].EffectiveDate, last = os[os.size()-1].EffectiveDate;
        for (Order o : os) {
            total += (o.TotalAmount == null ? 0 : o.TotalAmount);
            if (o.EffectiveDate >= ref.addDays(-30)) last30++;
        }
        Integer tenure = Math.max(first.daysBetween(ref), 1);
        Decimal cadence = os.size() > 1 ? Decimal.valueOf(tenure) / (os.size()-1) : 45;
        rows.add(new Churn_Training__c(
            Account__c = aid, Ref_Date__c = ref,
            Orders_Count__c = os.size(),
            Total_Spend__c = total.setScale(2),
            Avg_Order_Value__c = (total / os.size()).setScale(2),
            Days_Since_Last_Order__c = last.daysBetween(ref),
            Tenure_Days__c = tenure,
            Cadence_Days__c = cadence.setScale(1),
            Orders_Last_30d__c = last30,
            Churned__c = !boughtAfter.contains(aid)));
    }
}
insert rows;
Integer churned = 0;
for (Churn_Training__c r : rows) if (r.Churned__c) churned++;
System.debug('ROWS=' + rows.size() + ' CHURNED=' + churned + ' RETAINED=' + (rows.size()-churned));
