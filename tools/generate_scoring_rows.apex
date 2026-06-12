// SCORING MODE: one Churn_Training__c row per buyer with features AS OF TODAY, INCLUDING the
// web-engagement features (events/dwell/recency) so the Einstein model can use browsing behavior.
// Churned__c is a placeholder (ignored at inference). KEEP these rows after scoring: the prediction
// PrimaryObjectPk = the Churn_Training__c record id, so the CRM rows are the reliable join source
// for writing scores back to Account (the Data Cloud DMO purges if the CRM source is deleted).
Date ref = Date.today();
delete [SELECT Id FROM Churn_Training__c];
List<Order> allOrders = [SELECT AccountId, EffectiveDate, TotalAmount FROM Order
                         WHERE AccountId != null AND EffectiveDate != null ORDER BY EffectiveDate];
Map<Id, List<Order>> pre = new Map<Id, List<Order>>();
for (Order o : allOrders) {
    if (!pre.containsKey(o.AccountId)) pre.put(o.AccountId, new List<Order>());
    pre.get(o.AccountId).add(o);
}
// web-engagement aggregates per account (stitched events only)
Map<Id, Integer> webCnt = new Map<Id, Integer>();
Map<Id, Decimal> webDwell = new Map<Id, Decimal>();
Map<Id, Date> webLast = new Map<Id, Date>();
for (AggregateResult ar : [SELECT Account__c a, COUNT(Id) c, SUM(Time_On_Page__c) d, MAX(Occurred_At__c) mx
                           FROM Web_Event__c WHERE Account__c != null AND Occurred_At__c = LAST_N_DAYS:30
                           GROUP BY Account__c]) {
    Id a = (Id) ar.get('a');
    webCnt.put(a, (Integer) ar.get('c'));
    webDwell.put(a, (Decimal) (ar.get('d') == null ? 0 : ar.get('d')));
}
for (AggregateResult ar : [SELECT Account__c a, MAX(Occurred_At__c) mx FROM Web_Event__c
                           WHERE Account__c != null GROUP BY Account__c]) {
    Datetime mx = (Datetime) ar.get('mx');
    if (mx != null) webLast.put((Id) ar.get('a'), mx.date());
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
    Integer webDays = webLast.containsKey(aid) ? webLast.get(aid).daysBetween(ref) : 9999;
    rows.add(new Churn_Training__c(
        Account__c = aid, Ref_Date__c = ref,
        Orders_Count__c = os.size(),
        Total_Spend__c = total.setScale(2),
        Avg_Order_Value__c = (total / os.size()).setScale(2),
        Days_Since_Last_Order__c = last.daysBetween(ref),
        Tenure_Days__c = tenure,
        Cadence_Days__c = cadence.setScale(1),
        Orders_Last_30d__c = last30,
        Web_Events_30d__c = webCnt.containsKey(aid) ? webCnt.get(aid) : 0,
        Web_Dwell_Total__c = webDwell.containsKey(aid) ? webDwell.get(aid) : 0,
        Web_Days_Since_Seen__c = webDays,
        Churned__c = false));
}
insert rows;
System.debug('SCORING_ROWS=' + rows.size());
