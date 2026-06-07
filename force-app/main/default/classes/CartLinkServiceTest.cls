@isTest
private class CartLinkServiceTest {
    @isTest static void buildsLinks() {
        Product2 p1 = new Product2(Name='Coffee X', Woo_Product_Id__c='40', IsActive=true);
        Product2 p2 = new Product2(Name='Grinder Y', Woo_Product_Id__c='68', IsActive=true);
        insert new List<Product2>{p1, p2};
        CartLinkService.Request r = new CartLinkService.Request();
        r.productIdsCsv = p1.Id + ',' + p2.Id;
        r.couponCode = 'SAVE10';
        Test.startTest();
        CartLinkService.Result res = CartLinkService.build(new List<CartLinkService.Request>{r})[0];
        // empty path
        CartLinkService.Result none = CartLinkService.build(new List<CartLinkService.Request>{ new CartLinkService.Request() })[0];
        Test.stopTest();
        System.assert(res.success, 'should build');
        System.assert(res.addToCartUrl.contains('kc_add=40,68'), 'multi-add url: ' + res.addToCartUrl);
        System.assert(res.addToCartUrl.contains('kc_coupon=SAVE10'), 'coupon in url');
        System.assert(res.perItemLinks.contains('add-to-cart=40') && res.perItemLinks.contains('add-to-cart=68'), 'per-item links');
        System.assertEquals(false, none.success, 'no products → fail');
    }
}
