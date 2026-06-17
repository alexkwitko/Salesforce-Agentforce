/**
 * WooReturnReceiptResource — signed WooCommerce supply-chain callback.
 *
 * When Woo/admin operations mark returned merchandise as received, this endpoint
 * triggers the Salesforce receipt workflow: issue the Woo refund, close the
 * ReturnOrder, close the Returns Case, and write the audit trail.
 *
 * URL: /services/apexrest/woo/return-receipt/
 * Security: HMAC-SHA256 over the raw body in X-Kwitko-Signature
 * or X-WC-Webhook-Signature, validated against Woo_Settings__c.Webhook_Secret__c.
 */
@RestResource(urlMapping='/woo/return-receipt/*')
global without sharing class WooReturnReceiptResource {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        if (res == null) {
            res = new RestResponse();
            RestContext.response = res;
        }
        res.addHeader('Content-Type', 'application/json');

        Blob body = req == null ? null : req.requestBody;
        String raw = body != null ? body.toString() : '';

        String secret = getSecret();
        if (String.isNotBlank(secret)) {
            String sig = headerValue(req, 'X-Kwitko-Signature');
            if (sig == null) sig = headerValue(req, 'X-WC-Webhook-Signature');
            if (body == null || sig == null) {
                res.statusCode = 401;
                res.responseBody = msg('missing signature');
                return;
            }
            String calc = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(secret)));
            if (calc != sig) {
                res.statusCode = 401;
                res.responseBody = msg('invalid signature');
                return;
            }
        }

        if (String.isBlank(raw) || !raw.trim().startsWith('{')) {
            res.statusCode = 200;
            res.responseBody = msg('ack');
            return;
        }

        try {
            Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(raw);
            ReturnReceiptService.Request rr = new ReturnReceiptService.Request();
            rr.returnOrderNumber = firstText(p, new List<String>{ 'return_order_number', 'returnOrderNumber', 'return_number' });
            rr.orderIdentifier = firstText(p, new List<String>{ 'order_id', 'woo_order_id', 'orderIdentifier', 'order_number' });
            rr.returnTracking = firstText(p, new List<String>{ 'tracking', 'return_tracking', 'returnTracking' });
            rr.receivedNote = buildReceivedNote(p);
            rr.confirmed = true;

            ReturnReceiptService.Result result = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ rr })[0];
            res.statusCode = result.success == true ? 200 : 422;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'ok' => result.success,
                'message' => result.message,
                'returnOrderNumber' => result.returnOrderNumber,
                'orderNumber' => result.orderNumber,
                'refundAmount' => result.refundAmount,
                'refundIssued' => result.refundIssued,
                'wooRefundId' => result.wooRefundId,
                'caseNumber' => result.caseNumber
            }));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = msg('error: ' + e.getMessage());
        }
    }

    private static String buildReceivedNote(Map<String, Object> p) {
        String note = firstText(p, new List<String>{ 'received_note', 'receivedNote', 'note' });
        String source = firstText(p, new List<String>{ 'source' });
        String user = firstText(p, new List<String>{ 'user', 'received_by', 'receivedBy' });
        List<String> parts = new List<String>();
        if (String.isNotBlank(note)) parts.add(note);
        if (String.isNotBlank(source)) parts.add('Source: ' + source);
        if (String.isNotBlank(user)) parts.add('Received by: ' + user);
        return parts.isEmpty() ? 'WooCommerce marked returned merchandise received.' : String.join(parts, ' | ');
    }

    private static String firstText(Map<String, Object> p, List<String> keys) {
        if (p == null || keys == null) return null;
        for (String key : keys) {
            Object v = p.get(key);
            if (v != null && String.isNotBlank(String.valueOf(v))) return String.valueOf(v).trim();
        }
        return null;
    }

    private static String getSecret() {
        Woo_Settings__c s = Woo_Settings__c.getOrgDefaults();
        return s != null ? s.Webhook_Secret__c : null;
    }

    private static String headerValue(RestRequest req, String name) {
        if (req == null || req.headers == null) return null;
        for (String k : req.headers.keySet()) {
            if (k.equalsIgnoreCase(name)) return req.headers.get(k);
        }
        return null;
    }

    private static Blob msg(String m) {
        return Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'message' => m }));
    }
}
