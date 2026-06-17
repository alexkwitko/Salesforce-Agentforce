@isTest
private class CartLinkServiceTest {
    @isTest static void buildsLinks() {
        Product2 p1 = new Product2(Name='Coffee X', Woo_Product_Id__c='40', IsActive=true);
        Product2 p2 = new Product2(Name='Grinder Y', Woo_Product_Id__c='68', IsActive=true);
        insert new List<Product2>{p1, p2};
        CartLinkService.Request r = new CartLinkService.Request();
        r.productIdsCsv = p1.Id + ',' + p1.Id + ',' + p2.Id;
        r.couponCode = 'SAVE10';
        CartLinkService.Request repeated = new CartLinkService.Request();
        repeated.productIdsCsv = p1.Id + ',' + p1.Id;
        repeated.couponCode = 'SAVE10';
        Test.startTest();
        CartLinkService.Result res = CartLinkService.build(new List<CartLinkService.Request>{r})[0];
        CartLinkService.Result repeatedRes = CartLinkService.build(new List<CartLinkService.Request>{repeated})[0];
        // empty path
        CartLinkService.Result none = CartLinkService.build(new List<CartLinkService.Request>{ new CartLinkService.Request() })[0];
        Test.stopTest();
        System.assert(res.success, 'should build');
        System.assert(res.addToCartUrl.contains('kc_add=40,40,68'), 'multi-add url preserves requested quantity: ' + res.addToCartUrl);
        System.assert(res.addToCartUrl.contains('kc_clear=1'), 'recommendation link starts from a clean cart: ' + res.addToCartUrl);
        System.assert(res.addToCartUrl.contains('kc_coupon=SAVE10'), 'coupon in url');
        System.assert(res.message.contains('clean cart'), 'agent-facing message explains the fresh cart');
        System.assert(res.perItemLinks.contains('add-to-cart=40') && res.perItemLinks.contains('add-to-cart=68'), 'per-item links');
        System.assert(repeatedRes.success, 'same-product quantity should build');
        System.assert(repeatedRes.addToCartUrl.contains('add-to-cart=40'), 'same-product quantity uses native Woo add-to-cart: ' + repeatedRes.addToCartUrl);
        System.assert(repeatedRes.addToCartUrl.contains('quantity=2'), 'same-product quantity is encoded natively: ' + repeatedRes.addToCartUrl);
        System.assert(!repeatedRes.addToCartUrl.contains('kc_add='), 'same-product quantity does not depend on the WPCode multi-add route: ' + repeatedRes.addToCartUrl);
        System.assertEquals(false, none.success, 'no products → fail');
    }
}
