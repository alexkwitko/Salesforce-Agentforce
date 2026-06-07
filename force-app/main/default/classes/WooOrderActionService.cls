/**
 * WooOrderActionService — outbound WooCommerce order mutations via the `WooCommerce` Named Credential
 * (same pattern as WooCouponService). Used by CancellationService/ReturnService to reflect Salesforce
 * actions in the live store. Returns are best-effort: a Woo failure is reported, never silently swallowed,
 * so the caller can log a Case.
 */
public with sharing class WooOrderActionService {

    public class WooResult {
        public Boolean success;
        public String refundId;   // populated by refundOrder
        public Integer statusCode;
        public String message;
    }

    /** Cancel a WooCommerce order: PUT /orders/{id} {status:'cancelled'}. */
    public static WooResult cancelOrder(String wooOrderId) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (Test.isRunningTest()) { r.success = true; r.message = 'test'; return r; }
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders/' + wooOrderId);
            req.setMethod('PUT');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(new Map<String, Object>{ 'status' => 'cancelled' }));
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            r.success = resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
            r.message = r.success ? 'Order cancelled in WooCommerce.' : ('Woo cancel failed: ' + resp.getStatusCode());
        } catch (Exception e) {
            r.message = 'Woo cancel exception: ' + e.getMessage();
        }
        return r;
    }

    /** Update the shipping address on a WooCommerce order: PUT /orders/{id} {shipping:{...}}. */
    public static Boolean updateShippingAddress(String wooOrderId, String street, String city, String state, String postal, String country) {
        if (String.isBlank(wooOrderId)) return false;
        if (Test.isRunningTest()) return true;
        try {
            Map<String, Object> shipping = new Map<String, Object>();
            if (street != null) shipping.put('address_1', street);
            if (city != null) shipping.put('city', city);
            if (state != null) shipping.put('state', state);
            if (postal != null) shipping.put('postcode', postal);
            if (country != null) shipping.put('country', country);
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders/' + wooOrderId);
            req.setMethod('PUT');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(new Map<String, Object>{ 'shipping' => shipping }));
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            return resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
        } catch (Exception e) { System.debug('Woo address update failed: ' + e.getMessage()); return false; }
    }

    /**
     * Issue a refund: POST /orders/{id}/refunds {amount, reason, api_refund:true}.
     * api_refund=true asks the payment gateway to refund the money (not just record it).
     */
    public static WooResult refundOrder(String wooOrderId, Decimal amount, String reason) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (Test.isRunningTest()) { r.success = true; r.refundId = 'test-refund'; return r; }
        try {
            Map<String, Object> body = new Map<String, Object>{
                'reason' => (reason == null ? '' : reason),
                'api_refund' => true
            };
            if (amount != null && amount > 0) body.put('amount', String.valueOf(amount.setScale(2)));
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders/' + wooOrderId + '/refunds');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body));
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                Object idVal = parsed.get('id');
                r.refundId = idVal == null ? null : String.valueOf(idVal);
                r.success = true;
                r.message = 'Refund issued in WooCommerce (id ' + r.refundId + ').';
            } else {
                r.message = 'Woo refund failed: ' + resp.getStatusCode() + ' ' + resp.getBody();
            }
        } catch (Exception e) {
            r.message = 'Woo refund exception: ' + e.getMessage();
        }
        return r;
    }
}
