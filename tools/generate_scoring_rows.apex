// SCORING MODE: one Churn_Training__c row per buyer with features AS OF TODAY.
// Churned__c is a placeholder (ignored at inference). These rows are TRANSIENT on the
// 5MB org: insert -> wait for the Churn_Training stream sync -> run the Data Cloud
// prediction job -> write scores back to Account -> DELETE + empty recycle bin.
Date ref = Date.today();
delete [SELECT Id FROM Churn_Training__c];
List<Order> allOrders = [SELECT AccountId, EffectiveDate, TotalAmount FROM Order
                         WHERE AccountId != null AND EffectiveDate != null ORDER BY EffectiveDate];
Map<Id, List<Order>> pre = new Map<Id, List<Order>>();
for (Order o : allOrders) {
    if (!pre.containsKey(o.AccountId)) pre.put(o.AccountId, new List<Order>());
    pre.get(o.AccountId).add(o);
}
List<Churn_Training__c> rows = new List<Churn_Training__c>();
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
        Churned__c = false));
}
insert rows;
System.debug('SCORING_ROWS=' + rows.size());
