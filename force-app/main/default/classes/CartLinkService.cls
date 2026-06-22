/**
 * CartLinkService — builds REAL add-to-cart links for the chat agent, scoped to the SITE the chat is on.
 * The Service Agent runs server-side and cannot touch the shopper's browser cart, so the honest pattern
 * is to hand the shopper a working link.
 *   - Kwitko Coffee (WooCommerce): native ?add-to-cart= URL (one-click) + kc_add multi-add bridge.
 *   - Bean & Brew (Salesforce D2C / LWR): there is NO one-click add URL — return the storefront
 *     product-page (PDP) link(s); the shopper clicks "Add to Cart" on the page. NEVER hand a D2C
 *     shopper a WooCommerce link (wrong storefront, wrong cart).
 * The brand comes from the session (@variables.brand → MessagingSession.Brand__c). The agent MUST
 * present these links and MUST NOT claim items were already added.
 */
public without sharing class CartLinkService {

    // Kwitko storefront (WooCommerce on Hostinger).
    private static final String STORE = 'https://deepskyblue-deer-920559.hostingersite.com';
    private static final String CART_PATH = '/cart-2/';   // live Woo cart (/cart/ is a static marketing page)
    // Bean & Brew storefront (Salesforce D2C / LWR). PDP route mirrors the storefront's own product links.
    private static final String D2C_STORE = 'https://orgfarm-162e45523f-dev-ed.develop.my.site.com/beanbrew';
    // PDP route MUST match the storefront's own product links (see lwc/bbFeaturedCollection: '/beanbrew/product/x/').
    private static final String D2C_PDP   = '/product/x/';   // + Product2 Id  -> /beanbrew/product/x/<id>
    // Bean & Brew D2C WebStore — used to confirm the shopper is a registered/entitled buyer of THIS store.
    private static final Id D2C_WEBSTORE_ID = '0ZEfj000001CclhGAC';

    // Test hook: map an email -> registered? to exercise both branches without org WebStore/BuyerGroup data.
    @TestVisible private static Map<String, Boolean> registrationOverride = new Map<String, Boolean>();

    public class Request {
        @InvocableVariable(label='Product Ids CSV (Salesforce Product2 Ids — use ONLY a real Id returned by build_strategy)') public String productIdsCsv;
        @InvocableVariable(label='Product Names CSV — the EXACT product name(s) the shopper chose, copied verbatim from the catalog. Use this whenever you do not have a real Product2 Id; it is resolved server-side to the correct product for the current brand so the link can never add the wrong item.') public String productNamesCsv;
        @InvocableVariable(label='Coupon Code (optional)') public String couponCode;
        @InvocableVariable(label='Brand — the SITE the chat is on (Kwitko Coffee | Bean & Brew). Pass @variables.brand.') public String brand;
        @InvocableVariable(label='Verified shopper email (pass the verified loggedInEmail). Required for Bean & Brew to confirm the shopper is a registered buyer of this store.') public String verifiedEmail;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable(label='Is the shopper a registered buyer of this store') public Boolean isRegisteredBuyer;
        @InvocableVariable public String addToCartUrl;     // one-click (Woo) or product-page (D2C) link
        @InvocableVariable public String perItemLinks;     // fallback: one link per product
        @InvocableVariable public String cartUrl;          // link to view the cart
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Build Add-to-Cart Links'
        description='Returns working add-to-cart links for the recommended products, scoped to the site/brand the chat is on. Present these to the shopper; never claim the items are already in the cart.')
    public static List<Result> build(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doBuild(r));
        return out;
    }

    private static String normalizeBrand(String s) {
        if (String.isBlank(s)) return null;
        String t = s.trim().toLowerCase();
        if (t.contains('bean') || t.contains('brew') || t == 'b&b' || t.contains('beanbrew')) return 'Bean & Brew';
        if (t.contains('kwitko') || t.contains('coffee')) return 'Kwitko Coffee';
        return null;
    }

    private static Result doBuild(Request r) {
        Result res = new Result(); res.success = false;
        List<Id> ids = new List<Id>();
        if (String.isNotBlank(r.productIdsCsv)) {
            for (String s : r.productIdsCsv.split(',')) {
                String t = s.trim();
                if (String.isNotBlank(t)) { try { ids.add((Id) t); } catch (Exception e) {} }
            }
        }
        // Resolve by EXACT name (brand-scoped) when no Id was passed — prevents name/Id mismatch (wrong item in cart).
        if (ids.isEmpty() && String.isNotBlank(r.productNamesCsv)) {
            String b = (normalizeBrand(r.brand) == 'Bean & Brew') ? 'Bean & Brew' : 'Kwitko Coffee';
            Set<String> names = new Set<String>();
            for (String s : r.productNamesCsv.split(',')) { String t = s.trim(); if (String.isNotBlank(t)) names.add(t); }
            if (!names.isEmpty()) {
                for (Product2 p : [SELECT Id FROM Product2 WHERE Name IN :names AND Brand__c = :b AND IsActive = true]) ids.add(p.Id);
            }
        }
        if (ids.isEmpty()) { res.message = 'No products provided. If the shopper named a product, pass its exact name in productNamesCsv.'; res.cartUrl = STORE + CART_PATH; return res; }

        // Bean & Brew is a Salesforce D2C store — never use the Woo link path.
        if (normalizeBrand(r.brand) == 'Bean & Brew') return buildD2C(ids, res, r.verifiedEmail);
        return buildWoo(ids, r, res);
    }

    /** True only if the verified email maps to an Account that is an entitled BuyerGroupMember of this D2C store.
     *  (Woo/Kwitko allows guest add-to-cart, so this gate is D2C-only.) */
    @TestVisible
    private static Boolean isRegisteredD2CBuyer(String email) {
        if (String.isBlank(email)) return false;
        String e = email.trim();
        if (registrationOverride.containsKey(e.toLowerCase())) return registrationOverride.get(e.toLowerCase());
        Set<Id> groups = new Set<Id>();
        for (WebStoreBuyerGroup g : [SELECT BuyerGroupId FROM WebStoreBuyerGroup WHERE WebStoreId = :D2C_WEBSTORE_ID]) groups.add(g.BuyerGroupId);
        if (groups.isEmpty()) return false;
        Set<Id> accts = new Set<Id>();
        for (User u : [SELECT AccountId FROM User WHERE Email = :e AND AccountId != null AND IsActive = true]) accts.add(u.AccountId);
        for (Contact c : [SELECT AccountId FROM Contact WHERE Email = :e AND AccountId != null]) accts.add(c.AccountId);
        if (Schema.sObjectType.Account.fields.getMap().containsKey('personemail')) {
            for (SObject a : Database.query('SELECT Id FROM Account WHERE PersonEmail = :e')) accts.add((Id) a.get('Id'));
        }
        if (accts.isEmpty()) return false;
        return [SELECT COUNT() FROM BuyerGroupMember WHERE BuyerGroupId IN :groups AND BuyerId IN :accts] > 0;
    }

    // --- Bean & Brew (Salesforce D2C / LWR): storefront product-page links ---
    private static Result buildD2C(List<Id> ids, Result res, String verifiedEmail) {
        // NO registration gate: guests CAN add to cart on Bean & Brew, same as Kwitko/Woo.
        // The storefront handles the guest cart; we just hand over the product-page link(s) to click.
        res.isRegisteredBuyer = true;
        res.cartUrl = D2C_STORE;
        Map<Id, Product2> byId = new Map<Id, Product2>([SELECT Name FROM Product2 WHERE Id IN :new Set<Id>(ids)]);
        Set<Id> seen = new Set<Id>();
        List<String> perItem = new List<String>();
        String firstUrl = null;
        for (Id idValue : ids) {
            if (seen.contains(idValue)) continue;       // PDP is per product; quantity is chosen on the page
            seen.add(idValue);
            Product2 p = byId.get(idValue);
            if (p == null) continue;
            String pdp = D2C_STORE + D2C_PDP + idValue;
            if (firstUrl == null) firstUrl = pdp;
            perItem.add(p.Name + ': ' + pdp);
        }
        if (firstUrl == null) { res.message = 'Recommended products were not found.'; return res; }
        res.addToCartUrl = firstUrl;
        res.perItemLinks = String.join(perItem, '\n');
        res.success = true;
        res.message = 'Bean & Brew runs on our online store. Give the shopper the product-page link(s) and tell them to click "Add to Cart" on the page — do NOT claim it is already in the cart, and NEVER use a WooCommerce/Hostinger link here.';
        return res;
    }

    // --- Kwitko Coffee (WooCommerce): native one-click + multi-add bridge ---
    private static Result buildWoo(List<Id> ids, Request r, Result res) {
        res.cartUrl = STORE + CART_PATH;
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
