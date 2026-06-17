@isTest
private class CartRestoreServiceTest {
    @testSetup
    static void setup() {
        Product2 p = new Product2(Name = 'Private Cart Bean', Family = 'Single-Origin', IsActive = true,
            Stock_On_Hand__c = 10, Woo_Product_Id__c = '91001');
        insert p;
        Cart__c c = new Cart__c(Shopper_Email__c = 'cart.private@example.com', Status__c = 'Abandoned',
            Item_Count__c = 1, Cart_Value__c = 19);
        insert c;
        insert new Cart_Item__c(Cart__c = c.Id, Product__c = p.Id, Quantity__c = 2, Unit_Price__c = 19,
            Line_Total__c = 38, SKU__c = 'PRIVATE-BEAN');
        insert new Customer_Journey__c(Name = 'cart.private@example.com',
            Email__c = 'cart.private@example.com', Coupon_Code__c = 'PRIVATE10',
            Coupon_Redeemed__c = false);
    }

    @isTest
    static void unverifiedCannotReadSavedCart() {
        CartRestoreService.Request r = new CartRestoreService.Request();
        r.email = 'cart.private@example.com';
        CartRestoreService.Result res = CartRestoreService.restore(new List<CartRestoreService.Request>{ r })[0];
        System.assertEquals(false, res.found, 'saved cart stays private');
        System.assertEquals(null, res.itemsSummary, 'items not leaked');
        System.assertEquals(null, res.couponCode, 'coupon not leaked');
        System.assert(res.message.contains(IdentityService.LOGIN_URL), 'sign-in required');
    }

    @isTest
    static void verifiedCanRestoreSavedCart() {
        CartRestoreService.Request r = new CartRestoreService.Request();
        r.email = 'cart.private@example.com';
        r.verifiedEmail = 'cart.private@example.com';
        CartRestoreService.Result res = CartRestoreService.restore(new List<CartRestoreService.Request>{ r })[0];
        System.assertEquals(true, res.found, res.message);
        System.assert(res.itemsSummary.contains('Private Cart Bean'), 'items returned only after verification');
        System.assertEquals('PRIVATE10', res.couponCode, 'coupon returned only after verification');
        System.assert(String.isNotBlank(res.restoreUrl), 'restore link provided');
        System.assert(res.restoreUrl.contains('add-to-cart=91001'), 'restore link re-adds the saved Woo product');
        System.assert(res.restoreUrl.contains('quantity=2'), 'restore link preserves the saved quantity');
        System.assert(res.restoreUrl.contains('kc_coupon=PRIVATE10'), 'restore link auto-applies the waiting coupon');
        System.assert(!res.restoreUrl.contains('/cart?'), 'restore link must not target the stale static cart page');
    }

    @isTest
    static void emptySavedCartIsNotReportedAsRestorable() {
        Cart__c emptyCart = new Cart__c(Shopper_Email__c = 'empty.cart@example.com', Status__c = 'Abandoned',
            Item_Count__c = 0, Cart_Value__c = 0);
        insert emptyCart;

        CartRestoreService.Request r = new CartRestoreService.Request();
        r.email = 'empty.cart@example.com';
        r.verifiedEmail = 'empty.cart@example.com';
        CartRestoreService.Result res = CartRestoreService.restore(new List<CartRestoreService.Request>{ r })[0];

        System.assertEquals(false, res.found, 'empty cart should not be presented as restorable');
        System.assert(res.message.contains('no restorable items'), res.message);
        System.assertEquals(null, res.restoreUrl, 'no restore link without items');
    }
}
