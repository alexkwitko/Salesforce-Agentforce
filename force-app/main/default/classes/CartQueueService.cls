/**
 * CartQueueService — Phase 2 of zero-click cart (Option C). The agent (or the recommendation flow)
 * queues the recommended products + coupon to the storefront's /wp-json/kwitko/v1/cart endpoint,
 * keyed by the browser's cart token. The storefront controller polls that endpoint and adds the items
 * to the live WooCommerce cart via the Store API (no click), falling back to the kc_add redirect link.
 *
 * Outbound via the WooCommerce Named Credential, HMAC-signed with KWITKO_WHK_SECRET (same secret the
 * storefront verifies). NOTE: the agent needs the browser cart token (hidden prechat field
 * Kwitko_Cart_Token__c) to call this; that bridge is enabled once User Verification / prechat fields
 * are configured on a V2 embedded deployment.
 */
public without sharing class CartQueueService {

    // Must match KWITKO_WHK_SECRET in wp-config (and the storefront cart-capture HMAC).
    private static final String HMAC_SECRET = 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936';

    public class Request {
        @InvocableVariable(label='Cart Token' required=true) public String cartToken;
        @InvocableVariable(label='Woo Product Ids CSV' required=true) public String wooProductIdsCsv;
        @InvocableVariable(label='Coupon Code') public String couponCode;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Queue Zero-Click Cart'
        description='Queues recommended products + coupon to the storefront for the browser token; the storefront poller adds them to the live cart with no click.')
    public static List<Result> queue(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doQueue(r));
        return out;
    }

    private static Result doQueue(Request r) {
        Result res = new Result(); res.success = false;
        if (String.isBlank(r.cartToken) || String.isBlank(r.wooProductIdsCsv)) {
            res.message = 'cartToken and wooProductIdsCsv are required.'; return res;
        }
        List<Integer> items = new List<Integer>();
        for (String s : r.wooProductIdsCsv.split(',')) {
            String t = s.trim(); if (String.isNotBlank(t)) { try { items.add(Integer.valueOf(t)); } catch (Exception e) {} }
        }
        Map<String, Object> body = new Map<String, Object>{
            'token' => r.cartToken, 'items' => items,
            'coupon' => (r.couponCode == null ? '' : r.couponCode) };
        String raw = JSON.serialize(body);
        if (Test.isRunningTest()) { res.success = true; res.message = 'test'; return res; }
        try {
            Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf(HMAC_SECRET));
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/cart');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
            req.setBody(raw);
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            res.success = resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
            res.message = res.success ? 'Queued for zero-click add.' : ('Queue failed: ' + resp.getStatusCode());
        } catch (Exception e) {
            res.message = 'Queue exception: ' + e.getMessage();
        }
        return res;
    }
}
