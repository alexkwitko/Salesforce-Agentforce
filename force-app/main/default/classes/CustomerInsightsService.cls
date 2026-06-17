/**
 * CustomerInsightsService
 * Computes per-individual (per-Account) Calculated Insights from real CRM
 * Order / OrderItem / Product2 data and writes them onto the Account so they
 * surface on the record page, feed the agent, AND propagate into Data Cloud
 * (Account is ingested into the Individual DMO).
 *
 * Two layers, exactly what an e-commerce retailer wants on a customer 360:
 *  - VALUE / RFM: order count, lifetime value, AOV, first/last order, recency,
 *    reorder cadence, RFM segment, lifecycle stage.
 *  - BUYING / TASTE PROFILE: favorite roast, bean type, brew style, decaf &
 *    flavored share, top categories — derived from line items × product attrs.
 *
 * Schedulable for recurring refresh; run() is callable from `sf apex run`.
 */
public with sharing class CustomerInsightsService implements Schedulable {

    public void execute(SchedulableContext sc) { run(); }

    public static String run() {
        // DataCloudAugmentationService owns these fields once an Account is
        // tied to a Unified Profile. This job is the CRM fallback writer; it
        // must not downgrade unified Account cache values with local-only CRM
        // counts or retired Web_Event__c aggregates.
        Set<Id> dataCloudOwned = dataCloudOwnedAccountIds();

        // 1) Order-level value metrics per account.
        Map<Id, Account> upd = new Map<Id, Account>();
        for (AggregateResult ar : [
                SELECT AccountId aid, COUNT(Id) cnt, SUM(TotalAmount) ltv,
                       MIN(EffectiveDate) firstD, MAX(EffectiveDate) lastD
                FROM Order
                WHERE AccountId != null
                GROUP BY AccountId]) {
            Id aid = (Id) ar.get('aid');
            if (dataCloudOwned.contains(aid)) continue;
            Integer cnt = (Integer) ar.get('cnt');
            Decimal ltv = (Decimal) ar.get('ltv');
            Date firstD = (Date) ar.get('firstD');
            Date lastD = (Date) ar.get('lastD');
            if (ltv == null) ltv = 0;

            Integer recency = (lastD == null) ? null : lastD.daysBetween(Date.today());
            Decimal aov = cnt > 0 ? (ltv / cnt).setScale(2) : 0;
            Decimal cadence = null;
            if (cnt > 1 && firstD != null && lastD != null) {
                cadence = (Decimal) firstD.daysBetween(lastD) / (cnt - 1);
                cadence = cadence.setScale(1);
            }

            Account a = new Account(Id = aid);
            a.Insights_Order_Count__c = cnt;
            a.Insights_LTV__c = ltv;
            a.Insights_AOV__c = aov;
            a.Insights_Last_Order_Date__c = lastD;
            a.Insights_Days_Since_Last_Order__c = recency;
            a.Insights_Avg_Days_Between_Orders__c = cadence;
            a.Insights_RFM_Segment__c = rfm(recency, cnt, ltv);
            a.Insights_Lifecycle_Stage__c = lifecycle(recency);
            a.Insights_Updated__c = System.now();
            upd.put(aid, a);
        }

        // 2) Buying / taste profile from line items × product attributes.
        Map<Id, Tally> tallies = new Map<Id, Tally>();
        for (OrderItem oi : [
                SELECT Order.AccountId, Quantity,
                       Product2.Roast_Level__c, Product2.Bean_Type__c,
                       Product2.Brew_Style__c, Product2.Is_Decaf__c,
                       Product2.Is_Flavored__c, Product2.Family
                FROM OrderItem
                WHERE Order.AccountId != null]) {
            Id aid = oi.Order.AccountId;
            if (dataCloudOwned.contains(aid)) continue;
            if (!tallies.containsKey(aid)) tallies.put(aid, new Tally());
            tallies.get(aid).add(oi);
        }
        for (Id aid : tallies.keySet()) {
            if (!upd.containsKey(aid)) upd.put(aid, new Account(Id = aid));
            upd.get(aid).Insights_Taste_Profile__c = tallies.get(aid).profile();
        }

        // 3) Service & returns (the health side of the 360).
        for (AggregateResult ar : [SELECT AccountId aid, COUNT(Id) c FROM Case
                                   WHERE AccountId != null GROUP BY AccountId]) {
            Id aid = (Id) ar.get('aid');
            if (dataCloudOwned.contains(aid)) continue;
            if (!upd.containsKey(aid)) upd.put(aid, new Account(Id = aid));
            upd.get(aid).Insights_Total_Cases__c = (Integer) ar.get('c');
        }
        for (AggregateResult ar : [SELECT AccountId aid, COUNT(Id) c FROM Case
                                   WHERE AccountId != null AND IsClosed = false GROUP BY AccountId]) {
            Id aid = (Id) ar.get('aid');
            if (dataCloudOwned.contains(aid)) continue;
            if (!upd.containsKey(aid)) upd.put(aid, new Account(Id = aid));
            upd.get(aid).Insights_Open_Cases__c = (Integer) ar.get('c');
        }
        for (AggregateResult ar : [SELECT AccountId aid, COUNT(Id) c FROM ReturnOrder
                                   WHERE AccountId != null GROUP BY AccountId]) {
            Id aid = (Id) ar.get('aid');
            if (dataCloudOwned.contains(aid)) continue;
            if (!upd.containsKey(aid)) upd.put(aid, new Account(Id = aid));
            upd.get(aid).Insights_Returns__c = (Integer) ar.get('c');
        }

        // 4) Legacy devices & web engagement for CRM-fallback accounts only.
        //    Unified-profile Accounts get SDK web/device/session data from
        //    DataCloudAugmentationService, so they are skipped above.
        for (AggregateResult ar : [SELECT Account__c aid,
                                          COUNT_DISTINCT(Device_Id__c) devs,
                                          COUNT_DISTINCT(Session_Id__c) sess,
                                          COUNT(Id) evts, MAX(Occurred_At__c) lastWeb
                                   FROM Web_Event__c
                                   WHERE Account__c != null GROUP BY Account__c]) {
            Id aid = (Id) ar.get('aid');
            if (dataCloudOwned.contains(aid)) continue;
            if (!upd.containsKey(aid)) upd.put(aid, new Account(Id = aid));
            Account a = upd.get(aid);
            a.Insights_Device_Count__c = (Integer) ar.get('devs');
            a.Insights_Session_Count__c = (Integer) ar.get('sess');
            a.Insights_Web_Events__c = (Integer) ar.get('evts');
            a.Insights_Last_Web_Activity__c = (Datetime) ar.get('lastWeb');
        }

        if (!upd.isEmpty()) update upd.values();
        return 'CustomerInsightsService: updated ' + upd.size() + ' account(s).';
    }

    private static Set<Id> dataCloudOwnedAccountIds() {
        Set<Id> accountIds = new Set<Id>();
        for (Account a : [
                SELECT Id
                FROM Account
                WHERE Data_Cloud_Unified_Individual_Id__c != null
                   OR Data_Cloud_Insight_Source__c LIKE 'Data Cloud%' ]) {
            accountIds.add(a.Id);
        }
        return accountIds;
    }

    // ---- RFM segmentation (simple, transparent thresholds) -----------------
    @TestVisible
    static String rfm(Integer recency, Integer freq, Decimal monetary) {
        if (recency == null) return 'No Purchases';
        Boolean recent = recency <= 60;
        Boolean frequent = freq >= 3;
        Boolean highValue = monetary >= 150;
        if (recent && frequent && highValue) return 'Champion';
        if (recent && frequent)             return 'Loyal';
        if (recent && highValue)            return 'Big Spender';
        if (recent)                         return 'Promising';
        if (frequent || highValue)          return 'At Risk (was valuable)';
        if (recency <= 180)                 return 'Needs Attention';
        return 'Hibernating';
    }

    @TestVisible
    static String lifecycle(Integer recency) {
        if (recency == null) return 'Unknown';
        if (recency <= 45)  return 'Active';
        if (recency <= 120) return 'Cooling';
        if (recency <= 240) return 'At Risk';
        return 'Lapsed';
    }

    /** Per-account attribute tally for the taste profile. */
    public class Tally {
        Map<String, Double> roast = new Map<String, Double>();
        Map<String, Double> bean  = new Map<String, Double>();
        Map<String, Double> brew  = new Map<String, Double>();
        Map<String, Double> cat   = new Map<String, Double>();
        Double coffeeQty = 0, decafQty = 0, flavoredQty = 0, totalQty = 0;

        void add(OrderItem oi) {
            Double q = (oi.Quantity == null) ? 1 : oi.Quantity;
            totalQty += q;
            if (oi.Product2 == null) return;
            bump(cat, oi.Product2.Family, q);
            String rl = oi.Product2.Roast_Level__c;
            String bt = oi.Product2.Bean_Type__c;
            String bs = oi.Product2.Brew_Style__c;
            Boolean isCoffee = (rl != null || bt != null);
            if (isCoffee) {
                coffeeQty += q;
                if (oi.Product2.Is_Decaf__c == true) decafQty += q;
                if (oi.Product2.Is_Flavored__c == true) flavoredQty += q;
            }
            bump(roast, rl, q);
            bump(bean, bt, q);
            bump(brew, bs, q);
        }
        void bump(Map<String, Double> m, String k, Double q) {
            if (String.isBlank(k)) return;
            m.put(k, (m.containsKey(k) ? m.get(k) : 0) + q);
        }
        String top(Map<String, Double> m) {
            String best; Double bestV = -1;
            for (String k : m.keySet()) { if (m.get(k) > bestV) { bestV = m.get(k); best = k; } }
            return best;
        }
        Integer pct(Double part, Double whole) {
            return (whole == null || whole == 0) ? 0 : (Integer) Math.round(part / whole * 100);
        }
        String topCats() {
            // up to 3 categories by qty
            List<String> ks = new List<String>(cat.keySet());
            for (Integer i = 0; i < ks.size(); i++) {
                for (Integer j = i + 1; j < ks.size(); j++) {
                    if (cat.get(ks[j]) > cat.get(ks[i])) { String t = ks[i]; ks[i] = ks[j]; ks[j] = t; }
                }
            }
            List<String> out = new List<String>();
            for (Integer i = 0; i < Math.min(3, ks.size()); i++) out.add(ks[i]);
            return String.join(out, ', ');
        }
        String profile() {
            String fr = top(roast), fb = top(bean), fbs = top(brew);
            List<String> parts = new List<String>();
            if (fr != null)  parts.add('Roast: ' + fr + ' (' + pct(roast.get(fr), coffeeQty) + '%)');
            if (fb != null)  parts.add('Bean: ' + fb + ' (' + pct(bean.get(fb), coffeeQty) + '%)');
            if (fbs != null) parts.add('Brew: ' + fbs);
            if (coffeeQty > 0) {
                parts.add('Decaf: ' + pct(decafQty, coffeeQty) + '%');
                parts.add('Flavored: ' + pct(flavoredQty, coffeeQty) + '%');
            }
            String tc = topCats();
            if (String.isNotBlank(tc)) parts.add('Top categories: ' + tc);
            parts.add('Based on ' + (Integer) totalQty + ' item(s).');
            return String.join(parts, ' | ');
        }
    }

    /** Schedule a daily refresh at 02:30. Idempotent. */
    public static String scheduleDaily() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger
                               WHERE CronJobDetail.Name = 'CustomerInsights-Daily']) {
            System.abortJob(ct.Id);
        }
        return System.schedule('CustomerInsights-Daily', '0 30 2 * * ?', new CustomerInsightsService());
    }
}
