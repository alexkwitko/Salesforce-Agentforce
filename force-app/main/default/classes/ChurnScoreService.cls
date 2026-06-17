/**
 * ChurnScoreService — daily operational churn/LTV scorer (rule-based, not AI) that
 * complements Data Cloud prediction output when that output has been generated and
 * written back. The trained-model setup is managed outside Apex in Einstein Studio /
 * Data Cloud, so current model-definition status must be verified in the org. This class writes the live
 * Churn_Score__c (0-1), Predicted_LTV__c, and value-at-risk Tier every night and
 * adjusts churn with website engagement from the Data Cloud Account cache first
 * and legacy Web_Event__c rows as fallback: a customer who is overdue to buy but
 * actively browsing is far from lost — the engagement damper keeps them out of
 * the "gone" bucket and the Web_* fields make them segmentable.
 * If Einstein/Data Cloud predictions are available, their written-back probability
 * lives in Data_Cloud_Churn_Risk__c. When both exist, downstream activation should
 * prefer the model-looking probability and fall back to this operational signal.
 * Runs as a scheduled job ("Kwitko Churn Scoring Daily"); bulk-safe.
 */
public with sharing class ChurnScoreService {

    private class Stat { Integer cnt = 0; Decimal sum = 0; Date last; Date first; }
    private class Web  { Integer cnt30 = 0; Datetime lastSeen; }

    public static Integer scoreAll() {
        Map<Id, Stat> byAcct = new Map<Id, Stat>();
        for (AggregateResult ar : [
                SELECT AccountId acct, COUNT(Id) c, SUM(TotalAmount) s,
                       MAX(EffectiveDate) mx, MIN(EffectiveDate) mn
                FROM Order
                WHERE AccountId != null AND EffectiveDate != null
                GROUP BY AccountId ]) {
            Stat st = new Stat();
            st.cnt  = (Integer) ar.get('c');
            st.sum  = (Decimal) ar.get('s');
            st.last = (Date) ar.get('mx');
            st.first = (Date) ar.get('mn');
            byAcct.put((Id) ar.get('acct'), st);
        }

        // website engagement signals. Legacy Web_Event__c rows are still supported,
        // but the SDK-first path now comes from DataCloudAugmentationService's
        // Account cache after Web_Event__c was decommissioned as the active store.
        Map<Id, Web> webByAcct = new Map<Id, Web>();
        for (AggregateResult ar : [
                SELECT Account__c acct, MAX(Occurred_At__c) mx
                FROM Web_Event__c WHERE Account__c != null GROUP BY Account__c ]) {
            Web w = new Web();
            w.lastSeen = (Datetime) ar.get('mx');
            webByAcct.put((Id) ar.get('acct'), w);
        }
        for (AggregateResult ar : [
                SELECT Account__c acct, COUNT(Id) c
                FROM Web_Event__c
                WHERE Account__c != null AND Occurred_At__c = LAST_N_DAYS:30
                GROUP BY Account__c ]) {
            Web w = webByAcct.get((Id) ar.get('acct'));
            if (w != null) w.cnt30 = (Integer) ar.get('c');
        }
        for (Account a : [
                SELECT Id, Insights_Web_Events__c, Insights_Last_Web_Activity__c
                FROM Account
                WHERE Insights_Last_Web_Activity__c != null OR Insights_Web_Events__c > 0 ]) {
            Web w = webByAcct.get(a.Id);
            if (w == null) {
                w = new Web();
                webByAcct.put(a.Id, w);
            }
            if (a.Insights_Last_Web_Activity__c != null
                    && (w.lastSeen == null || a.Insights_Last_Web_Activity__c > w.lastSeen)) {
                w.lastSeen = a.Insights_Last_Web_Activity__c;
            }
            if ((w.cnt30 == null || w.cnt30 == 0) && a.Insights_Web_Events__c != null) {
                w.cnt30 = a.Insights_Web_Events__c.intValue();
            }
        }

        if (byAcct.isEmpty() && webByAcct.isEmpty()) return 0;

        Date today = Date.today();
        Map<Id, Account> ups = new Map<Id, Account>();
        for (Id aid : byAcct.keySet()) {
            Stat st = byAcct.get(aid);
            if (st.sum == null) st.sum = 0;
            Integer recency = st.last.daysBetween(today);
            Integer tenure  = Math.max(st.first.daysBetween(today), 1);

            // normal buying cadence (days between orders); floor at 7
            Decimal cadence = st.cnt > 1 ? Decimal.valueOf(tenure) / (st.cnt - 1) : 45;
            if (cadence < 7) cadence = 7;

            // churn: how far past 2x normal cadence the customer has gone (0-1)
            Decimal churn = Decimal.valueOf(recency) / (2 * cadence);
            if (churn > 1) churn = 1;
            if (churn < 0) churn = 0;

            // engagement damper: an overdue buyer who is browsing the site is not lost
            Web w = webByAcct.get(aid);
            if (w != null && w.lastSeen != null) {
                Integer webDays = w.lastSeen.date().daysBetween(today);
                if (webDays <= 14)      churn = churn * 0.6;
                else if (webDays <= 45) churn = churn * 0.85;
            }
            churn = churn.setScale(2, System.RoundingMode.HALF_UP);

            // predicted forward 12-month value = annualized historical spend (customer's worth)
            Decimal years = Decimal.valueOf(tenure) / 365;
            if (years < 0.5) years = 0.5;
            Decimal ltv = (st.sum / years).setScale(2, System.RoundingMode.HALF_UP);

            Decimal valueAtRisk = churn * ltv;
            String tier = valueAtRisk >= 250 ? 'A' : (valueAtRisk >= 80 ? 'B' : 'C');

            ups.put(aid, new Account(
                Id = aid,
                Churn_Score__c = churn,
                Predicted_LTV__c = ltv,
                Churn_Risk_Tier__c = tier,
                Web_Events_30d__c = w != null ? w.cnt30 : 0,
                Web_Last_Seen__c = w != null ? w.lastSeen : null,
                Last_Scored__c = System.now()));
        }

        // engagement-only visitors (no orders yet): keep their web fields current too
        for (Id aid : webByAcct.keySet()) {
            if (ups.containsKey(aid)) continue;
            Web w = webByAcct.get(aid);
            ups.put(aid, new Account(
                Id = aid,
                Web_Events_30d__c = w.cnt30,
                Web_Last_Seen__c = w.lastSeen,
                Last_Scored__c = System.now()));
        }

        update ups.values();
        return ups.size();
    }

    public class Scheduler implements Schedulable {
        public void execute(SchedulableContext sc) { ChurnScoreService.scoreAll(); }
    }
}
