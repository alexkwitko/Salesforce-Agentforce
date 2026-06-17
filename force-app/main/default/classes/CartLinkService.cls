/**
 * CartLinkService — builds REAL WooCommerce add-to-cart links for the chat agent.
 * The Agentforce Service Agent runs server-side and cannot touch the shopper's browser cart, so the
 * honest pattern is to hand the shopper a working add-to-cart URL. Use WooCommerce's
 * native add-to-cart URL for single-product quantities and the kc_add storefront
 * handler for multi-product bundles when that WPCode bridge is installed.
 *
 * The agent MUST present these links and MUST NOT claim items were already added.
 */
public without sharing class CartLinkService {

    // Storefront base URL (WooCommerce on Hostinger).
    private static final String STORE = 'https://deepskyblue-deer-920559.hostingersite.com';
    // Real WooCommerce cart page on this storefront is /cart-2/ (/cart/ is a static marketing page, NOT the live cart).
    private static final String CART_PATH = '/cart-2/';

    public class Request {
        @InvocableVariable(label='Product Ids CSV (Salesforce Product2 Ids to add)' required=true) public String productIdsCsv;
        @InvocableVariable(label='Coupon Code (optional)') public String couponCode;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String addToCartUrl;     // one-click link that adds the recommended item(s)
        @InvocableVariable public String perItemLinks;     // fallback: one native add-to-cart link per product
        @InvocableVariable public String cartUrl;          // link to view the cart
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Build Add-to-Cart Links'
        description='Returns working WooCommerce add-to-cart links for the recommended products. Present these to the shopper; never claim the items are already in the cart.')
    public static List<Result> build(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doBuild(r));
        return out;
    }

    private static Result doBuild(Request r) {
        Result res = new Result(); res.success = false; res.cartUrl = STORE + CART_PATH;
        List<Id> ids = new List<Id>();
        if (String.isNotBlank(r.productIdsCsv)) {
            for (String s : r.productIdsCsv.split(',')) {
                String t = s.trim();
                if (String.isNotBlank(t)) { try { ids.add((Id) t); } catch (Exception e) {} }
            }
        }
        if (ids.isEmpty()) { res.message = 'No products provided.'; return res; }

        Map<Id, Product2> productsById = new Map<Id, Product2>(
            [SELECT Name, Woo_Product_Id__c FROM Product2 WHERE Id IN :new Set<Id>(ids) AND Woo_Product_Id__c != null]
        );
        List<String> wooIds = new List<String>();
        List<String> perItem = new List<String>();
        for (Id idValue : ids) {
            Product2 p = productsById.get(idValue);
            if (p == null) continue;
            wooIds.add(p.Woo_Product_Id__c);
            perItem.add(p.Name + ': ' + STORE + '/?add-to-cart=' + p.Woo_Product_Id__c);
        }
        if (wooIds.isEmpty()) { res.message = 'Recommended products are not yet synced to the store.'; return res; }

        Map<String, Integer> qtyByWooId = new Map<String, Integer>();
        for (String wooId : wooIds) {
            qtyByWooId.put(wooId, (qtyByWooId.containsKey(wooId) ? qtyByWooId.get(wooId) : 0) + 1);
        }

        String url;
        if (qtyByWooId.size() == 1) {
            String wooId = new List<String>(qtyByWooId.keySet())[0];
            url = STORE + '/?add-to-cart=' + wooId + '&quantity=' + String.valueOf(qtyByWooId.get(wooId));
        } else {
            // Multi-add requires the kc_add storefront handler; native per-item links remain the fallback.
            url = STORE + '/?kc_add=' + String.join(wooIds, ',') + '&kc_clear=1';
        }
        if (String.isNotBlank(r.couponCode)) url += '&kc_coupon=' + EncodingUtil.urlEncode(r.couponCode.trim(), 'UTF-8');
        res.addToCartUrl = url;
        res.perItemLinks = String.join(perItem, '\n');
        res.success = true;
        res.message = qtyByWooId.size() == 1
            ? 'Native WooCommerce cart link ready. Tell the shopper the item is added only after they click; do not claim the item is already in the cart.'
            : 'Fresh-cart recommendation link ready. Tell the shopper the link opens a clean cart with these items and applies the coupon; do not claim the items are already added.';
        return res;
    }
}
