/**
 * CartLinkService — builds REAL WooCommerce add-to-cart links for the chat agent.
 * The Agentforce Service Agent runs server-side and cannot touch the shopper's browser cart, so the
 * honest pattern is to hand the shopper a working add-to-cart URL. WooCommerce native
 * ?add-to-cart=<wooId> adds the item to the live cart (verified on the storefront).
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
        @InvocableVariable public String addToCartUrl;     // one-click link that adds ALL items (kc_add handler)
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
        Set<Id> ids = new Set<Id>();
        if (String.isNotBlank(r.productIdsCsv)) {
            for (String s : r.productIdsCsv.split(',')) {
                String t = s.trim();
                if (String.isNotBlank(t)) { try { ids.add((Id) t); } catch (Exception e) {} }
            }
        }
        if (ids.isEmpty()) { res.message = 'No products provided.'; return res; }

        List<String> wooIds = new List<String>();
        List<String> perItem = new List<String>();
        for (Product2 p : [SELECT Name, Woo_Product_Id__c FROM Product2 WHERE Id IN :ids AND Woo_Product_Id__c != null]) {
            wooIds.add(p.Woo_Product_Id__c);
            perItem.add(p.Name + ': ' + STORE + '/?add-to-cart=' + p.Woo_Product_Id__c);
        }
        if (wooIds.isEmpty()) { res.message = 'Recommended products are not yet synced to the store.'; return res; }

        // one-click multi-add (requires the kc_add storefront handler); falls back to per-item native links
        String url = STORE + '/?kc_add=' + String.join(wooIds, ',');
        if (String.isNotBlank(r.couponCode)) url += '&kc_coupon=' + r.couponCode.trim();
        res.addToCartUrl = url;
        res.perItemLinks = String.join(perItem, '\n');
        res.success = true;
        res.message = 'Add-to-cart links ready. Present the link(s) to the shopper; do not claim the items are already added.';
        return res;
    }
}
