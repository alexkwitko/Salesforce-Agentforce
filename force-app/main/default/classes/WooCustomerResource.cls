/**
 * WooCustomerResource — public REST endpoint that receives WooCommerce account/profile updates
 * (name, marketing consent, billing/shipping address) and syncs them to the Salesforce Person Account.
 * URL: /services/apexrest/woo/customer/   (exposed via the Salesforce Site to the guest user)
 * Security: HMAC-SHA256 over the raw body in X-Kwitko-Signature, validated against Woo_Settings__c.
 */
@RestResource(urlMapping='/woo/customer/*')
global without sharing class WooCustomerResource {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Blob body = req.requestBody;
        String raw = body != null ? body.toString() : '';

        String secret = getSecret();
        if (String.isNotBlank(secret)) {
            String sig = headerValue(req, 'X-Kwitko-Signature');
            if (sig == null) sig = headerValue(req, 'X-WC-Webhook-Signature');
            if (body == null || sig == null) { res.statusCode = 401; res.responseBody = msg('missing signature'); return; }
            String calc = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(secret)));
            if (calc != sig) { res.statusCode = 401; res.responseBody = msg('invalid signature'); return; }
        }
        if (String.isBlank(raw) || !raw.trim().startsWith('{')) { res.statusCode = 200; res.responseBody = msg('ack'); return; }

        try {
            Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(raw);
            Id accId = WooCustomerService.upsertProfile(p);
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'ok' => true, 'accountId' => accId }));
        } catch (Exception e) {
            res.statusCode = 500; res.responseBody = msg('error: ' + e.getMessage());
        }
    }

    static String getSecret() { Woo_Settings__c s = Woo_Settings__c.getOrgDefaults(); return s != null ? s.Webhook_Secret__c : null; }
    static String headerValue(RestRequest req, String name) {
        for (String k : req.headers.keySet()) if (k.equalsIgnoreCase(name)) return req.headers.get(k);
        return null;
    }
    static Blob msg(String m) { return Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'message' => m })); }
}
