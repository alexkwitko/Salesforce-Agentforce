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

    @isTest static void beanBrewUsesD2CStoreNotWoo() {
        // A Bean & Brew product may even carry a Woo id, but on the D2C site the cart must be the D2C storefront.
        Product2 bb = new Product2(Name='Bean & Brew Commercial Burr Grinder', Brand__c='Bean & Brew',
                                   Woo_Product_Id__c='563', IsActive=true);
        insert bb;
        CartLinkService.registrationOverride.put('buyer@beanbrew.test', true); // treat as a registered buyer
        CartLinkService.Request r = new CartLinkService.Request();
        r.productIdsCsv = bb.Id;
        r.brand = 'Bean & Brew';
        r.verifiedEmail = 'buyer@beanbrew.test';
        Test.startTest();
        CartLinkService.Result res = CartLinkService.build(new List<CartLinkService.Request>{ r })[0];
        Test.stopTest();
        System.assert(res.success, 'D2C link should build for a registered buyer');
        System.assertEquals(true, res.isRegisteredBuyer, 'registered buyer flagged');
        System.assert(res.addToCartUrl.contains('my.site.com/beanbrew'), 'D2C link must point at the Bean & Brew storefront: ' + res.addToCartUrl);
        System.assert(res.addToCartUrl.contains('/beanbrew/product/x/' + bb.Id), 'D2C link must be the storefront product page: ' + res.addToCartUrl);
        System.assert(!res.addToCartUrl.contains('hostingersite.com') && !res.addToCartUrl.contains('add-to-cart='),
                      'D2C link must NOT be a WooCommerce link: ' + res.addToCartUrl);
    }

    @isTest static void beanBrewBlocksNonRegisteredBuyer() {
        // A verified shopper who is NOT a registered buyer of the Bean & Brew store gets no links.
        Product2 bb = new Product2(Name='Bean & Brew Descaling Kit', Brand__c='Bean & Brew', IsActive=true);
        insert bb;
        CartLinkService.registrationOverride.put('alexkwitko@gmail.com', false);
        CartLinkService.Request r = new CartLinkService.Request();
        r.productIdsCsv = bb.Id;
        r.brand = 'Bean & Brew';
        r.verifiedEmail = 'alexkwitko@gmail.com';
        Test.startTest();
        CartLinkService.Result res = CartLinkService.build(new List<CartLinkService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(false, res.success, 'non-registered buyer must not get links');
        System.assertEquals(false, res.isRegisteredBuyer, 'flagged not registered');
        System.assert(res.message.contains('NOT A REGISTERED BUYER'), 'message tells the agent to say so: ' + res.message);
        System.assertEquals(null, res.addToCartUrl, 'no add-to-cart url for a non-buyer');
    }

    @isTest static void blankEmailIsNotRegistered() {
        Product2 bb = new Product2(Name='Bean & Brew Milk Frother', Brand__c='Bean & Brew', IsActive=true);
        insert bb;
        CartLinkService.Request r = new CartLinkService.Request();
        r.productIdsCsv = bb.Id; r.brand = 'Bean & Brew'; // no verifiedEmail
        Test.startTest();
        CartLinkService.Result res = CartLinkService.build(new List<CartLinkService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(false, res.success, 'no verified email -> cannot confirm buyer -> blocked');
        System.assert(res.message.contains('NOT A REGISTERED BUYER'), 'blocked message');
    }
}
