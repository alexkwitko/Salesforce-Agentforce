/**
 * WooCouponService — shared helper that creates a percent-discount coupon in
 * WooCommerce (enforcement layer) via the WooCommerce Named Credential.
 * Returns the Woo coupon id (string) or null on failure.
 */
public with sharing class WooCouponService {

    public static String createPercentCoupon(String code, Integer pct, Date expiry,
                                             String email, List<String> wooProductIds) {
        Map<String, Object> body = new Map<String, Object>{
            'code' => code,
            'discount_type' => 'percent',
            'amount' => String.valueOf(pct),
            'individual_use' => true,
            'usage_limit' => 1,
            'usage_limit_per_user' => 1,
            'date_expires' => String.valueOf(expiry) + 'T23:59:59'
        };
        if (String.isNotBlank(email)) {
            body.put('email_restrictions', new List<String>{ email });
        }
        if (wooProductIds != null && !wooProductIds.isEmpty()) {
            List<Integer> ids = new List<Integer>();
            for (String s : wooProductIds) { if (String.isNotBlank(s)) ids.add(Integer.valueOf(s)); }
            if (!ids.isEmpty()) body.put('product_ids', ids);
        }
        return post(body);
    }

    /** Fixed-amount store-credit / goodwill coupon (discount_type fixed_cart). */
    public static String createFixedCoupon(String code, Decimal amount, Date expiry, String email) {
        Map<String, Object> body = new Map<String, Object>{
            'code' => code,
            'discount_type' => 'fixed_cart',
            'amount' => String.valueOf(amount),
            'individual_use' => false,
            'usage_limit' => 1,
            'usage_limit_per_user' => 1,
            'date_expires' => String.valueOf(expiry) + 'T23:59:59'
        };
        if (String.isNotBlank(email)) body.put('email_restrictions', new List<String>{ email });
        return post(body);
    }

    private static String post(Map<String, Object> body) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/coupons');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body));
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                Object idVal = parsed.get('id');
                return idVal == null ? null : String.valueOf(idVal);
            }
            System.debug('Woo coupon push failed: ' + resp.getStatusCode() + ' ' + resp.getBody());
        } catch (Exception e) {
            System.debug('Woo coupon push exception: ' + e.getMessage());
        }
        return null;
    }
}
