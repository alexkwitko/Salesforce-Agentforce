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
        insert new Cart_Item__c(Cart__c = c.Id, Product__c = p.Id, Quantity__c = 1, Unit_Price__c = 19,
            Line_Total__c = 19, SKU__c = 'PRIVATE-BEAN');
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
    }
}
