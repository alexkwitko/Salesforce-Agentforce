/**
 * WooOrderActionService — outbound WooCommerce order mutations via the `WooCommerce` Named Credential
 * (same pattern as WooCouponService). Used by CancellationService/ReturnService to reflect Salesforce
 * actions in the live store. Returns are best-effort: a Woo failure is reported, never silently swallowed,
 * so the caller can log a Case.
 */
public with sharing class WooOrderActionService {
    @TestVisible private static Boolean allowHttpInTests = false;
    private static final String MIN_FAIL_CLOSED_MAIL_BRIDGE_VERSION = '20260615.7';

    public class WooResult {
        public Boolean success;
        public String refundId;   // populated by refundOrder
        public String noteId;     // populated by addCustomerNote
        public Integer statusCode;
        public String message;
    }

    public class RefundLine {
        public String wooLineItemId;
        public Decimal refundTotal;
        public RefundLine(String wooLineItemId, Decimal refundTotal) {
            this.wooLineItemId = wooLineItemId;
            this.refundTotal = refundTotal;
        }
    }

    /** Cancel a WooCommerce order: PUT /orders/{id} {status:'cancelled'}. */
    public static WooResult cancelOrder(String wooOrderId) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (Test.isRunningTest() && !allowHttpInTests) { r.success = true; r.message = 'test'; return r; }
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
        if (Test.isRunningTest() && !allowHttpInTests) return true;
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
     * Ask WooCommerce/WordPress to send the customer-facing return-label email.
     * This is stronger than relying only on a customer note because the storefront endpoint
     * deliberately invokes the Woo mailer and returns an explicit success/failure result.
     */
    public static WooResult sendReturnLabelEmail(String wooOrderId, String toEmail, String orderNumber,
            String labelUrl, String trackingNumber, String itemsSummary) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (String.isBlank(toEmail)) { r.message = 'No customer email.'; return r; }
        if (String.isBlank(labelUrl) || String.isBlank(trackingNumber)) { r.message = 'No return label.'; return r; }
        if (Test.isRunningTest() && !allowHttpInTests) { r.success = true; r.message = 'test'; return r; }
        try {
            WooResult trust = requireFailClosedMailBridge('return-label');
            if (trust != null) return trust;

            Map<String, Object> body = new Map<String, Object>{
                'order_id' => wooOrderId,
                'to_email' => toEmail,
                'order_number' => orderNumber,
                'label_url' => labelUrl,
                'tracking' => trackingNumber,
                'items' => String.isBlank(itemsSummary) ? '' : itemsSummary
            };
            String raw = JSON.serialize(body);
            Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf(KwitkoSecrets.whk()));
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/return-label-email');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
            req.setBody(raw);
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            r.success = resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
            r.message = r.success ? 'WooCommerce return-label email sent.' : ('Woo label email failed: ' + resp.getStatusCode() + ' ' + resp.getBody());
        } catch (Exception e) {
            r.message = 'Woo label email exception: ' + e.getMessage();
        }
        return r;
    }

    /**
     * Ask WooCommerce/WordPress to send an OTP through the storefront mailer.
     * This is a fallback for dev/demo orgs that exhaust Salesforce SingleEmail limits.
     */
    public static WooResult sendVerificationCodeEmail(String toEmail, String code, Integer expiresMinutes) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(toEmail)) { r.message = 'No customer email.'; return r; }
        if (String.isBlank(code)) { r.message = 'No verification code.'; return r; }
        if (Test.isRunningTest() && !allowHttpInTests) { r.success = true; r.message = 'test'; return r; }
        try {
            WooResult trust = requireFailClosedMailBridge('verification');
            if (trust != null) return trust;

            Map<String, Object> body = new Map<String, Object>{
                'to_email' => toEmail,
                'code' => code,
                'expires_minutes' => expiresMinutes == null ? 10 : expiresMinutes
            };
            String raw = JSON.serialize(body);
            Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf(KwitkoSecrets.whk()));
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/verification-code-email');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
            req.setBody(raw);
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            r.success = resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
            r.message = r.success ? 'WooCommerce verification email sent.' : ('Woo verification email failed: ' + resp.getStatusCode() + ' ' + resp.getBody());
        } catch (Exception e) {
            r.message = 'Woo verification email exception: ' + e.getMessage();
        }
        return r;
    }

    /**
     * Issue a refund: POST /orders/{id}/refunds {amount, reason, api_refund:true}.
     * api_refund=true asks the payment gateway to refund the money (not just record it).
     */
    public static WooResult refundOrder(String wooOrderId, Decimal amount, String reason) {
        return refundOrder(wooOrderId, amount, reason, null);
    }

    /**
     * Issue a refund with optional Woo line-item refund totals for partial returns.
     */
    public static WooResult refundOrder(String wooOrderId, Decimal amount, String reason, List<RefundLine> refundLines) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (Test.isRunningTest() && !allowHttpInTests) { r.success = true; r.refundId = 'test-refund'; return r; }
        try {
            Map<String, Object> body = new Map<String, Object>{
                'reason' => (reason == null ? '' : reason),
                'api_refund' => true
            };
            if (amount != null && amount > 0) body.put('amount', String.valueOf(amount.setScale(2)));
            List<Object> lineItems = new List<Object>();
            if (refundLines != null) {
                for (RefundLine line : refundLines) {
                    if (line == null || String.isBlank(line.wooLineItemId) || line.refundTotal == null || line.refundTotal <= 0) continue;
                    Map<String, Object> item = new Map<String, Object>();
                    item.put('id', parseWooId(line.wooLineItemId));
                    item.put('refund_total', String.valueOf(line.refundTotal.setScale(2)));
                    lineItems.add(item);
                }
            }
            if (!lineItems.isEmpty()) body.put('line_items', lineItems);
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

    /**
     * Add a WooCommerce order note. With customerNote=true, Woo treats it as customer-visible and
     * sends the store-side customer notification according to Woo's order-note behavior.
     */
    public static WooResult addCustomerNote(String wooOrderId, String note, Boolean customerNote) {
        WooResult r = new WooResult(); r.success = false;
        if (String.isBlank(wooOrderId)) { r.message = 'No Woo order id.'; return r; }
        if (String.isBlank(note)) { r.message = 'No note text.'; return r; }
        if (Test.isRunningTest() && !allowHttpInTests) { r.success = true; r.noteId = 'test-note'; return r; }
        try {
            Map<String, Object> body = new Map<String, Object>{
                'note' => note,
                'customer_note' => customerNote == true
            };
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders/' + wooOrderId + '/notes');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body));
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                Object idVal = parsed.get('id');
                r.noteId = idVal == null ? null : String.valueOf(idVal);
                r.success = true;
                r.message = 'WooCommerce order note created.';
            } else {
                r.message = 'Woo order note failed: ' + resp.getStatusCode() + ' ' + resp.getBody();
            }
        } catch (Exception e) {
            r.message = 'Woo order note exception: ' + e.getMessage();
        }
        return r;
    }

    private static Object parseWooId(String value) {
        try { return Integer.valueOf(value); }
        catch (Exception e) { return value; }
    }

    private static WooResult requireFailClosedMailBridge(String purpose) {
        WooResult r = new WooResult();
        r.success = false;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/me');
            req.setMethod('GET');
            req.setTimeout(15000);
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            String version = null;
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300 && String.isNotBlank(resp.getBody())) {
                Object decoded = JSON.deserializeUntyped(resp.getBody());
                if (decoded instanceof Map<String, Object>) {
                    Object rawVersion = ((Map<String, Object>) decoded).get('bridge_version');
                    version = rawVersion == null ? null : String.valueOf(rawVersion);
                }
            }
            if (bridgeVersionAtLeast(version, MIN_FAIL_CLOSED_MAIL_BRIDGE_VERSION)) return null;
            r.message = 'Woo ' + purpose + ' email blocked: live Kwitko bridge version '
                + (String.isBlank(version) ? 'unknown' : version)
                + ' does not have fail-closed mail delivery. Deploy WPCode '
                + MIN_FAIL_CLOSED_MAIL_BRIDGE_VERSION + '+ before trusting Woo email.';
        } catch (Exception e) {
            r.message = 'Woo ' + purpose + ' email blocked: could not verify fail-closed mail bridge: ' + e.getMessage();
        }
        return r;
    }

    @TestVisible
    private static Boolean bridgeVersionAtLeast(String version, String minimum) {
        if (String.isBlank(version) || String.isBlank(minimum)) return false;
        List<String> currentParts = version.split('\\.');
        List<String> minimumParts = minimum.split('\\.');
        Integer maxParts = Math.max(currentParts.size(), minimumParts.size());
        for (Integer i = 0; i < maxParts; i++) {
            Integer current = i < currentParts.size() ? versionPart(currentParts[i]) : 0;
            Integer required = i < minimumParts.size() ? versionPart(minimumParts[i]) : 0;
            if (current > required) return true;
            if (current < required) return false;
        }
        return true;
    }

    private static Integer versionPart(String raw) {
        if (String.isBlank(raw)) return 0;
        String digits = raw.replaceAll('[^0-9]', '');
        return String.isBlank(digits) ? 0 : Integer.valueOf(digits);
    }
}
