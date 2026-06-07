/**
 * CouponAnalyticsService — efficiency analytics over the personalization program:
 *   1) Coupon efficiency: issued vs redeemed rate + total discount given.
 *   2) Recommendation conversion: of the products the engine recommended, how many were purchased.
 *
 * Reads the Customer_Journey__c memory (Coupon_* fields + Recommended/Purchased product id CSVs).
 * Exposed as a static method (reports/anon Apex) and an invocable (agent/flow surfacing).
 */
public without sharing class CouponAnalyticsService {

    public class Metrics {
        @InvocableVariable public Integer couponsIssued;
        @InvocableVariable public Integer couponsRedeemed;
        @InvocableVariable public Decimal redemptionRatePct;
        @InvocableVariable public Decimal totalDiscountGiven;
        @InvocableVariable public Integer customersWithRecommendations;
        @InvocableVariable public Integer recommendedProductsTotal;
        @InvocableVariable public Integer recommendedProductsPurchased;
        @InvocableVariable public Decimal recommendationConversionPct;
        @InvocableVariable public String summary;
    }

    @InvocableMethod(label='Get Personalization Efficiency Metrics'
        description='Returns coupon issued/redeemed rate, total discount given, and recommended→purchased conversion across all customer journeys.')
    public static List<Metrics> getMetrics(List<String> ignored) {
        return new List<Metrics>{ summarize() };
    }

    public static Metrics summarize() {
        Metrics m = new Metrics();
        Integer issued = 0, redeemed = 0;
        Decimal discount = 0;
        Integer custWithRec = 0, recTotal = 0, recPurchased = 0;

        // NB: Recommended_Product_Ids__c is a Long Text Area and cannot be filtered in SOQL,
        // so we scan all journeys and filter in-memory.
        for (Customer_Journey__c j : [
                SELECT Coupon_Code__c, Coupon_Redeemed__c, Coupon_Discount_Amount__c,
                       Recommended_Product_Ids__c, Purchased_Product_Ids__c
                FROM Customer_Journey__c LIMIT 50000]) {

            if (String.isNotBlank(j.Coupon_Code__c)) {
                issued++;
                if (j.Coupon_Redeemed__c == true) {
                    redeemed++;
                    if (j.Coupon_Discount_Amount__c != null) discount += j.Coupon_Discount_Amount__c;
                }
            }

            Set<String> rec = csvToSet(j.Recommended_Product_Ids__c);
            if (!rec.isEmpty()) {
                custWithRec++;
                recTotal += rec.size();
                Set<String> bought = csvToSet(j.Purchased_Product_Ids__c);
                for (String id : rec) if (bought.contains(id)) recPurchased++;
            }
        }

        m.couponsIssued = issued;
        m.couponsRedeemed = redeemed;
        m.redemptionRatePct = issued == 0 ? 0 : ((Decimal) redeemed / issued * 100).setScale(1);
        m.totalDiscountGiven = discount.setScale(2);
        m.customersWithRecommendations = custWithRec;
        m.recommendedProductsTotal = recTotal;
        m.recommendedProductsPurchased = recPurchased;
        m.recommendationConversionPct = recTotal == 0 ? 0 : ((Decimal) recPurchased / recTotal * 100).setScale(1);
        m.summary = 'Coupons: ' + redeemed + '/' + issued + ' redeemed ('
            + m.redemptionRatePct + '%), $' + m.totalDiscountGiven + ' discount given. '
            + 'Recommendations: ' + recPurchased + '/' + recTotal + ' purchased ('
            + m.recommendationConversionPct + '% conversion) across ' + custWithRec + ' customers.';
        return m;
    }

    private static Set<String> csvToSet(String csv) {
        Set<String> out = new Set<String>();
        if (String.isBlank(csv)) return out;
        for (String s : csv.split(',')) { String t = s.trim(); if (String.isNotBlank(t)) out.add(t); }
        return out;
    }
}
