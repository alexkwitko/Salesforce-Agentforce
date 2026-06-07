/**
 * CartRestoreService — lets the Concierge bring back a shopper's saved/abandoned cart.
 * The cart is persisted server-side (Cart__c + Cart_Item__c) the moment the storefront captures it, so
 * even if the browser session was lost nothing is gone. Given an email, this finds the most recent
 * Active/Abandoned cart, lists what was in it, and returns a ONE-CLICK link (via CartLinkService) that
 * re-adds every item — and auto-applies any unredeemed coupon already waiting for them. Read-only + a
 * link build (no callout), so it's safe to call inline from the agent.
 */
public without sharing class CartRestoreService {

    private static final String CART_URL = 'https://deepskyblue-deer-920559.hostingersite.com/cart';

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail — required to restore private saved-cart contents)') public String verifiedEmail;
    }
    public class Result {
        @InvocableVariable public Boolean found;
        @InvocableVariable public Integer itemCount;
        @InvocableVariable public String itemsSummary;   // "2× Brazil Santos, 1× AeroPress"
        @InvocableVariable public String restoreUrl;     // one-click: re-adds all items (+coupon)
        @InvocableVariable public String couponCode;     // unredeemed coupon auto-applied, if any
        @InvocableVariable public String message;        // agent-facing summary
    }

    @InvocableMethod(label='Restore Saved Cart'
        description='Finds the shopper saved or abandoned cart and returns a one-click link that re-adds every item plus any waiting coupon. Use when a returning shopper may have lost their cart.')
    public static List<Result> restore(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r.email, r.verifiedEmail));
        return out;
    }

    private static Result build(String email, String verifiedEmail) {
        Result res = new Result();
        res.found = false; res.itemCount = 0;
        if (String.isBlank(email)) { res.message = 'No email provided.'; return res; }
        if (!IdentityService.isVerified(email, verifiedEmail)) {
            res.message = IdentityService.signInMessage();
            return res;
        }

        List<Cart__c> carts = [SELECT Id, Status__c, Item_Count__c, Cart_Value__c FROM Cart__c
            WHERE Shopper_Email__c = :email AND Status__c IN ('Active','Abandoned')
            ORDER BY LastModifiedDate DESC LIMIT 1];
        if (carts.isEmpty()) { res.message = 'No saved cart found for ' + email + '.'; return res; }

        List<Cart_Item__c> items = [SELECT Quantity__c, SKU__c, Product__c, Product__r.Name
            FROM Cart_Item__c WHERE Cart__c = :carts[0].Id ORDER BY Line_Total__c DESC];
        List<Id> prodIds = new List<Id>();
        List<String> parts = new List<String>();
        for (Cart_Item__c it : items) {
            Integer q = it.Quantity__c == null ? 1 : it.Quantity__c.intValue();
            String nm = (it.Product__r != null && it.Product__r.Name != null) ? it.Product__r.Name : (String.isBlank(it.SKU__c) ? 'item' : it.SKU__c);
            parts.add(q + '× ' + nm);
            if (it.Product__c != null) prodIds.add(it.Product__c);
        }
        res.itemCount = items.size();
        res.itemsSummary = String.join(parts, ', ');

        // unredeemed coupon already waiting for this shopper (cross-agent: e.g. the cart-recovery coupon)
        for (Customer_Journey__c j : [SELECT Coupon_Code__c, Coupon_Redeemed__c FROM Customer_Journey__c WHERE Email__c = :email LIMIT 1]) {
            if (String.isNotBlank(j.Coupon_Code__c) && j.Coupon_Redeemed__c != true) res.couponCode = j.Coupon_Code__c;
        }

        res.restoreUrl = CART_URL;
        if (!prodIds.isEmpty()) {
            try {
                CartLinkService.Request cr = new CartLinkService.Request();
                cr.productIdsCsv = idsToCsv(prodIds);
                cr.couponCode = res.couponCode;
                CartLinkService.Result lr = CartLinkService.build(new List<CartLinkService.Request>{ cr })[0];
                if (String.isNotBlank(lr.addToCartUrl)) res.restoreUrl = lr.addToCartUrl;
            } catch (Exception e) { /* keep cart url fallback */ }
        }

        res.found = true;
        res.message = 'Saved ' + carts[0].Status__c + ' cart: ' + res.itemsSummary
            + (String.isBlank(res.couponCode) ? '' : ' (coupon ' + res.couponCode + ' will auto-apply)')
            + '. Offer the one-click restore link.';
        return res;
    }

    private static String idsToCsv(List<Id> ids) {
        List<String> s = new List<String>();
        for (Id i : ids) if (i != null) s.add(String.valueOf(i));
        return String.join(s, ',');
    }
}
