// Point-in-time churn training snapshots: features from orders BEFORE each ref date,
// label churned = NO order in the 60 days AFTER. All real history, no leakage.
// Web-engagement features (events/dwell/recency before each ref date) are INCLUDED so the model
// trains with browsing behavior as inputs. NOTE: web tracking is recent, so historical ref dates
// carry ~0 engagement — the columns are real model inputs whose predictive value grows as
// engagement history accumulates (honest current state, not a fabricated signal).
Date[] refs = new Date[]{ Date.newInstance(2026,1,15), Date.newInstance(2026,2,1),
                          Date.newInstance(2026,3,1),  Date.newInstance(2026,4,1) };
delete [SELECT Id FROM Churn_Training__c];
List<Order> allOrders = [SELECT AccountId, EffectiveDate, TotalAmount FROM Order
                         WHERE AccountId != null AND EffectiveDate != null ORDER BY EffectiveDate];
List<Web_Event__c> allWeb = [SELECT Account__c, Occurred_At__c, Time_On_Page__c FROM Web_Event__c
                             WHERE Account__c != null AND Occurred_At__c != null ORDER BY Occurred_At__c];
List<Churn_Training__c> rows = new List<Churn_Training__c>();
for (Date ref : refs) {
    // web aggregates as of this ref date
    Map<Id, Integer> wCnt = new Map<Id, Integer>();
    Map<Id, Decimal> wDwell = new Map<Id, Decimal>();
    Map<Id, Date> wLast = new Map<Id, Date>();
    Date win30 = ref.addDays(-30);
    for (Web_Event__c w : allWeb) {
        Date wd = w.Occurred_At__c.date();
        if (wd >= ref) continue;                         // no leakage past the ref date
        if (!wLast.containsKey(w.Account__c) || wd > wLast.get(w.Account__c)) wLast.put(w.Account__c, wd);
        if (wd >= win30) {
            wCnt.put(w.Account__c, (wCnt.containsKey(w.Account__c) ? wCnt.get(w.Account__c) : 0) + 1);
            Decimal d = w.Time_On_Page__c == null ? 0 : w.Time_On_Page__c;
            wDwell.put(w.Account__c, (wDwell.containsKey(w.Account__c) ? wDwell.get(w.Account__c) : 0) + d);
        }
    }
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
        Integer webDays = wLast.containsKey(aid) ? wLast.get(aid).daysBetween(ref) : 9999;
        rows.add(new Churn_Training__c(
            Account__c = aid, Ref_Date__c = ref,
            Orders_Count__c = os.size(),
            Total_Spend__c = total.setScale(2),
            Avg_Order_Value__c = (total / os.size()).setScale(2),
            Days_Since_Last_Order__c = last.daysBetween(ref),
            Tenure_Days__c = tenure,
            Cadence_Days__c = cadence.setScale(1),
            Orders_Last_30d__c = last30,
            Web_Events_30d__c = wCnt.containsKey(aid) ? wCnt.get(aid) : 0,
            Web_Dwell_Total__c = wDwell.containsKey(aid) ? wDwell.get(aid) : 0,
            Web_Days_Since_Seen__c = webDays,
            Churned__c = !boughtAfter.contains(aid)));
    }
}
insert rows;
Integer churned = 0;
for (Churn_Training__c r : rows) if (r.Churned__c) churned++;
System.debug('ROWS=' + rows.size() + ' CHURNED=' + churned + ' RETAINED=' + (rows.size()-churned));
