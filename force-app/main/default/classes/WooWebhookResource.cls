/**
 * Public REST endpoint for WooCommerce order webhooks.
 * URL: /services/apexrest/woo/order/  (exposed via a Salesforce Site to the guest user)
 * Security: validates the WooCommerce HMAC-SHA256 signature (X-WC-Webhook-Signature)
 * against the shared secret stored in the Woo_Settings__c custom setting.
 */
@RestResource(urlMapping='/woo/order/*')
global without sharing class WooWebhookResource {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Blob body = req.requestBody;
        String raw = body != null ? body.toString() : '';

        // --- HMAC signature validation ---
        String secret = getSecret();
        if (String.isNotBlank(secret)) {
            String sig = headerValue(req, 'X-WC-Webhook-Signature');
            if (body == null || sig == null) { res.statusCode = 401; res.responseBody = msg('missing signature'); return; }
            String calc = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(secret)));
            if (calc != sig) { res.statusCode = 401; res.responseBody = msg('invalid signature'); return; }
        }

        // WooCommerce sends a non-JSON "ping" when the webhook is created — ack it.
        if (String.isBlank(raw) || !raw.trim().startsWith('{')) { res.statusCode = 200; res.responseBody = msg('ack'); return; }

        try {
            Map<String, Object> order = (Map<String, Object>) JSON.deserializeUntyped(raw);
            if (order.get('id') == null) { res.statusCode = 200; res.responseBody = msg('ignored: no order id'); return; }
            Id orderId = WooOrderService.ingestOrder(order);
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'ok' => true, 'salesforceOrderId' => orderId, 'wooOrderId' => order.get('id') }));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = msg('error: ' + e.getMessage());
        }
    }

    static String getSecret() {
        Woo_Settings__c s = Woo_Settings__c.getOrgDefaults();
        return (s != null) ? s.Webhook_Secret__c : null;
    }

    static String headerValue(RestRequest req, String name) {
        for (String k : req.headers.keySet()) {
            if (k.equalsIgnoreCase(name)) return req.headers.get(k);
        }
        return null;
    }

    static Blob msg(String m) {
        return Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'message' => m }));
    }
}
