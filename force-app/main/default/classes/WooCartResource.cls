/**
 * WooCartResource — public REST endpoint that captures LIVE WooCommerce carts so the
 * abandoned-cart agent can act on them. WooCommerce core emits NO "abandoned cart" event
 * (a cart lives in the browser session), so a storefront snippet POSTs the current cart here
 * on cart change / checkout-start. We store it as an Active Cart__c; AbandonedCartSweep flips it
 * to Abandoned after 1h of inactivity with no order, which triggers the existing Lead flow.
 *
 * URL: /services/apexrest/woo/cart/   (exposed via the existing Salesforce Site to the guest user)
 * Security: HMAC-SHA256 over the raw body in header X-Kwitko-Signature, validated against the
 * shared secret in Woo_Settings__c (same secret as the order webhook). The snippet runs
 * server-side (PHP) so the secret is never exposed to the browser.
 *
 * Body JSON:
 *  { "cart_id":"<woo session key>", "email":"a@b.com", "first_name":"A", "last_name":"B",
 *    "consent":true, "total":53.40,
 *    "items":[ {"product_id":45,"sku":"BEAN-..","name":"Brazil Santos","quantity":2,"price":19.0} ] }
 */
@RestResource(urlMapping='/woo/cart/*')
global without sharing class WooCartResource {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Blob body = req.requestBody;
        String raw = body != null ? body.toString() : '';

        // --- HMAC validation (skip only if no secret configured) ---
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
            Id cartId = upsertCart(p);
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'ok' => true, 'cartId' => cartId }));
        } catch (Exception e) {
            res.statusCode = 500; res.responseBody = msg('error: ' + e.getMessage());
        }
    }

    /** Upsert one Cart__c (Active) + replace its Cart_Item__c lines. Public for test reuse. */
    public static Id upsertCart(Map<String, Object> p) {
        String cartKey = str(p.get('cart_id'));
        String email = str(p.get('email'));
        if (String.isBlank(cartKey)) cartKey = String.isNotBlank(email) ? ('email:' + email) : null;
        if (String.isBlank(cartKey)) return null; // nothing to key on

        String name = (str(p.get('first_name')) + ' ' + str(p.get('last_name'))).trim();
        Boolean consent = p.get('consent') == true || str(p.get('consent')) == 'true' || str(p.get('consent')) == '1';
        Decimal total = dec(p.get('total'));

        List<Object> items = (p.get('items') instanceof List<Object>) ? (List<Object>) p.get('items') : new List<Object>();
        Integer count = 0;
        for (Object io : items) {
            Map<String, Object> it = (Map<String, Object>) io;
            count += (Integer) (dec(it.get('quantity')) == null ? 0 : dec(it.get('quantity')).intValue());
        }

        List<Cart__c> existing = [SELECT Id, Status__c, Email_Consent__c FROM Cart__c WHERE Woo_Cart_Id__c = :cartKey LIMIT 1];
        Cart__c c = existing.isEmpty() ? new Cart__c(Woo_Cart_Id__c = cartKey) : existing[0];
        // never resurrect a converted cart
        if (!existing.isEmpty() && c.Status__c == 'Converted') return c.Id;
        c.Status__c = 'Active';
        c.Last_Activity__c = System.now();
        c.Cart_Value__c = total;
        c.Item_Count__c = count;
        if (String.isNotBlank(email)) c.Shopper_Email__c = email;
        if (String.isNotBlank(name)) c.Shopper_Name__c = name;
        if (consent) c.Email_Consent__c = true; // never downgrade an opt-in
        else if (existing.isEmpty()) c.Email_Consent__c = false;
        upsert c;

        // replace line items
        delete [SELECT Id FROM Cart_Item__c WHERE Cart__c = :c.Id];
        Map<String, Id> prodByWoo = new Map<String, Id>();
        Set<String> wooIds = new Set<String>();
        for (Object io : items) { String w = str(((Map<String, Object>) io).get('product_id')); if (String.isNotBlank(w)) wooIds.add(w); }
        if (!wooIds.isEmpty()) {
            for (Product2 pr : [SELECT Id, Woo_Product_Id__c FROM Product2 WHERE Woo_Product_Id__c IN :wooIds]) {
                prodByWoo.put(pr.Woo_Product_Id__c, pr.Id);
            }
        }
        List<Cart_Item__c> lines = new List<Cart_Item__c>();
        for (Object io : items) {
            Map<String, Object> it = (Map<String, Object>) io;
            Decimal qty = dec(it.get('quantity')); Decimal price = dec(it.get('price'));
            lines.add(new Cart_Item__c(
                Cart__c = c.Id,
                Product__c = prodByWoo.get(str(it.get('product_id'))),
                SKU__c = str(it.get('sku')),
                Quantity__c = qty == null ? 1 : qty,
                Unit_Price__c = price == null ? 0 : price,
                Line_Total__c = (qty == null ? 1 : qty) * (price == null ? 0 : price)));
        }
        if (!lines.isEmpty()) insert lines;
        return c.Id;
    }

    static String getSecret() { Woo_Settings__c s = Woo_Settings__c.getOrgDefaults(); return s != null ? s.Webhook_Secret__c : null; }
    static String headerValue(RestRequest req, String name) {
        for (String k : req.headers.keySet()) if (k.equalsIgnoreCase(name)) return req.headers.get(k);
        return null;
    }
    static String str(Object o) { return o == null ? '' : String.valueOf(o); }
    static Decimal dec(Object o) { try { return o == null ? null : Decimal.valueOf(String.valueOf(o)); } catch (Exception e) { return null; } }
    static Blob msg(String m) { return Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'message' => m })); }
}
