/**
 * StoreCreditService — a REAL fix tool for the Service agent (not just an audit).
 * Issues goodwill store credit (a one-time fixed-amount WooCommerce coupon) to make things right for a
 * shopper after a delay/damage/service failure, records it as a Coupon__c, and logs it to the customer
 * journey so every agent sees the make-good. Capped at $50 to bound AI-issued credit.
 */
public without sharing class StoreCreditService {

    private static final Decimal MAX_CREDIT = 50;
    private static final Decimal DEFAULT_CREDIT = 5;

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Amount (USD, optional — defaults to 5, capped at 50)') public Decimal amount;
        @InvocableVariable(label='Reason') public String reason;
        @InvocableVariable(label='Verified Email (pass loggedInEmail — required to issue credit)') public String verifiedEmail;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper accepts this goodwill credit.') public Boolean confirmed;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String couponCode;
        @InvocableVariable public Decimal amount;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Apply Store Credit'
        description='Issues goodwill store credit (a one-time fixed-amount coupon in WooCommerce) to make things right for the shopper, records it, and logs it to the journey. A real make-it-right tool, not just an audit.')
    public static List<Result> apply(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doApply(r));
        return out;
    }

    private static Result doApply(Request r) {
        Result res = new Result(); res.success = false;
        if (!IdentityService.isVerified(r.email, r.verifiedEmail)) { res.message = IdentityService.signInMessage(); return res; }
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) { res.message = 'No account found for that email — confirm it or ask them to sign in.'; return res; }
        if (r.confirmed != true) { res.message = 'Please confirm the shopper accepts this store credit before I issue it.'; return res; }

        Decimal amt = (r.amount == null || r.amount <= 0) ? DEFAULT_CREDIT : (r.amount > MAX_CREDIT ? MAX_CREDIT : r.amount);
        res.amount = amt;
        String reason = String.isBlank(r.reason) ? 'Goodwill / service recovery' : r.reason.trim();
        Date expiry = Date.today().addDays(30);
        String code = 'KWCREDIT' + String.valueOf(Math.mod(Math.abs((r.email + String.valueOf(amt)).hashCode()), 100000));
        res.couponCode = code;

        // Callout first (create the coupon in WooCommerce), then DML.
        String wooId = WooCouponService.createFixedCoupon(code, amt, expiry, r.email);

        if ([SELECT count() FROM Coupon__c WHERE Code__c = :code] == 0) {
            insert new Coupon__c(Name = code, Code__c = code, Account__c = acc.Id, Expiry_Date__c = expiry,
                Status__c = 'Issued', Woo_Coupon_Id__c = wooId,
                Recommendation_Summary__c = 'Store credit $' + amt.setScale(2) + ' — ' + reason);
        }
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = r.email; lr.agent = 'Service'; lr.action = 'apply_store_credit'; lr.stage = 'Service';
            lr.result = 'Issued $' + amt.setScale(2) + ' store credit ' + code + ' — ' + reason;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.message = 'Issued $' + amt.setScale(2) + ' store credit (code ' + code + ', expires ' + expiry.format()
            + ') to ' + r.email + '. Reason: ' + reason + '.';
        return res;
    }
}
