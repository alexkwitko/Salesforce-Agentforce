/**
 * CouponService — agent action that issues a REAL, single-use, personalized WooCommerce percent
 * coupon for the shopper (code tied to their name + recorded on their journey), and returns the
 * code so the agent can auto-apply it via the add-to-cart link (kc_coupon=...). The discount %
 * comes from the deterministic strategy engine, never invented by the agent.
 */
public without sharing class CouponService {

    public class Request {
        @InvocableVariable(label='Email' required=false) public String email;
        @InvocableVariable(label='Discount Percent' required=true) public Decimal discountPercent;
        @InvocableVariable(label='First Name (for a personalized code)') public String firstName;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String couponCode;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Issue Personalized Coupon'
        description='Creates a real single-use WooCommerce percent coupon for this shopper, records it on their journey, and returns the code. Pass discountPercent from the strategy engine. Give the code to add_to_cart so it auto-applies.')
    public static List<Result> issue(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doIssue(r));
        return out;
    }

    private static Result doIssue(Request r) {
        Result res = new Result(); res.success = false;
        if (r.discountPercent == null || r.discountPercent <= 0) {
            res.message = 'Coupon not issued because the strategy marked this shopper ineligible for a sales discount.';
            return res;
        }
        Integer pct = Integer.valueOf(r.discountPercent);
        String who = String.isBlank(r.firstName) ? 'FRIEND' : r.firstName.toUpperCase().replaceAll('[^A-Z0-9]', '');
        if (String.isBlank(who)) who = 'FRIEND';
        if (who.length() > 8) who = who.substring(0, 8);
        String rnd = String.valueOf(Math.abs(Crypto.getRandomInteger()));
        rnd = rnd.length() >= 4 ? rnd.right(4) : rnd.leftPad(4, '0');
        String code = 'KW-' + who + '-' + pct + '-' + rnd;

        Date expiry = Date.today().addDays(30);
        String shopperEmail = String.isBlank(r.email) ? null : r.email.trim().toLowerCase();
        String wooId = Test.isRunningTest() ? 'test'
            : WooCouponService.createPercentCoupon(code, pct, expiry, shopperEmail, null);
        if (wooId == null) { res.message = 'Could not create the coupon in the store.'; return res; }

        res.couponCode = code; res.success = true;
        res.message = 'Created single-use coupon ' + code + ' for ' + pct + '% off.';

        Id accountId;
        if (String.isNotBlank(shopperEmail)) {
            Account acc = KwitkoServiceUtil.findAccount(shopperEmail);
            if (acc != null) accountId = acc.Id;

            Customer_Journey__c j = JourneyService.getOrCreate(shopperEmail, null, null);
            if (j != null) {
                j.Coupon_Code__c = code;
                j.Coupon_Issued_Date__c = System.now();
                j.Coupon_Discount_Percent__c = pct;
                j.Coupon_Redeemed__c = false;   // fresh issue; redemption set later at order ingestion
                update j;
            }
        }
        if ([SELECT count() FROM Coupon__c WHERE Code__c = :code] == 0) {
            String summary = 'Chat sales coupon'
                + (String.isBlank(shopperEmail) ? '' : ' for ' + shopperEmail)
                + ' — single-use ' + pct + '% off; email-restricted in WooCommerce.';
            insert new Coupon__c(
                Name = code,
                Code__c = code,
                Account__c = accountId,
                Discount_Percent__c = pct,
                Expiry_Date__c = expiry,
                Status__c = 'Issued',
                Woo_Coupon_Id__c = wooId,
                Recommendation_Summary__c = summary
            );
        }
        return res;
    }
}
