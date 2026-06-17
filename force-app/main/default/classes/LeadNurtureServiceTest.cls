@isTest
private class LeadNurtureServiceTest {

    private static List<String> wooMockMethods = new List<String>();

    private class WooCouponMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            wooMockMethods.add(req.getMethod());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"id":777,"code":"comeback"}');
            return res;
        }
    }

    @isTest
    static void testSendRecovery() {
        Product2 p = new Product2(Name='Recovery Bean', Family='Single-Origin', IsActive=true,
            Stock_On_Hand__c=10, Woo_Product_Id__c='88001');
        insert p;
        Lead l = new Lead(FirstName='Sam', LastName='Shopper', Company='Online Shopper',
            Email='sam.shopper@example.com', Status='Open - Not Contacted',
            Email_Consent__c=true, Last_Cart_Value__c=60);
        insert l;
        Cart__c cart = new Cart__c(Status__c='Abandoned', Email_Consent__c=true, Lead__c=l.Id,
            Shopper_Email__c='sam.shopper@example.com', Cart_Value__c=60, Item_Count__c=1,
            Woo_Cart_Id__c='sam-cart-1');
        insert cart;
        insert new Cart_Item__c(Cart__c=cart.Id, Product__c=p.Id, Quantity__c=1,
            Unit_Price__c=60, Line_Total__c=60, SKU__c='RECOVERY-BEAN');

        Test.setMock(HttpCalloutMock.class, new WooCouponMock());
        Test.startTest();
        LeadNurtureService.Request req = new LeadNurtureService.Request();
        req.leadId = l.Id;
        List<LeadNurtureService.Result> rs = LeadNurtureService.sendRecovery(
            new List<LeadNurtureService.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, rs[0].success, 'should succeed');
        System.assert(rs[0].couponCode.startsWith('COMEBACK'), 'code: ' + rs[0].couponCode);
        System.assertNotEquals(
            'COMEBACK' + String.valueOf(Math.mod(Math.abs(l.Id.hashCode()), 10000)),
            rs[0].couponCode,
            'recovery code must be cart-scoped so an old lead-level Woo coupon cannot block future carts'
        );
        System.assert(
            rs[0].couponCode.endsWith(String.valueOf(cart.Id).right(8).toUpperCase()),
            'code should carry the cart fingerprint: ' + rs[0].couponCode
        );

        Lead l2 = [SELECT Status FROM Lead WHERE Id=:l.Id];
        System.assertEquals('Working - Contacted', l2.Status, 'lead marked contacted');

        Coupon__c c = [SELECT Woo_Coupon_Id__c, Discount_Percent__c FROM Coupon__c WHERE Code__c=:rs[0].couponCode LIMIT 1];
        System.assertEquals('777', c.Woo_Coupon_Id__c, 'woo id captured');
        System.assertEquals(10, c.Discount_Percent__c);
    }

    @isTest
    static void testNoCartItemsDoesNotSendRecovery() {
        Lead l = new Lead(FirstName='Empty', LastName='Shopper', Company='Online Shopper',
            Email='empty.shopper@example.com', Status='Open - Not Contacted',
            Email_Consent__c=true, Last_Cart_Value__c=60);
        insert l;

        Test.startTest();
        LeadNurtureService.Result r = LeadNurtureService.run(l.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'empty cart context must not send a fake recovery');
        System.assert(r.message.contains('No abandoned cart items'), r.message);
        System.assertEquals('Open - Not Contacted', [SELECT Status FROM Lead WHERE Id = :l.Id].Status,
            'lead must not be marked contacted when no cart exists');
        System.assertEquals(0, [SELECT count() FROM Coupon__c], 'no coupon should be created');
    }

    @isTest
    static void testUnlinkedCartItemsDoNotSendRecovery() {
        Lead l = new Lead(FirstName='Sku', LastName='Shopper', Company='Online Shopper',
            Email='sku.shopper@example.com', Status='Open - Not Contacted',
            Email_Consent__c=true, Last_Cart_Value__c=60);
        insert l;
        Cart__c cart = new Cart__c(Status__c='Abandoned', Email_Consent__c=true, Lead__c=l.Id,
            Shopper_Email__c='sku.shopper@example.com', Cart_Value__c=60, Item_Count__c=1,
            Woo_Cart_Id__c='sku-cart-1');
        insert cart;
        insert new Cart_Item__c(Cart__c=cart.Id, Quantity__c=1,
            Unit_Price__c=60, Line_Total__c=60, SKU__c='UNLINKED-SKU');

        Test.startTest();
        LeadNurtureService.Result r = LeadNurtureService.run(l.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'unlinked cart cannot build a restore link');
        System.assert(r.message.contains('no Salesforce-linked products'), r.message);
        System.assertEquals(0, [SELECT count() FROM Coupon__c], 'no coupon should be created');
    }

    @isTest
    static void testEmailFailureDoesNotMarkRecoveredOrPersistCoupon() {
        Product2 p = new Product2(Name='Failure Bean', Family='Single-Origin', IsActive=true,
            Stock_On_Hand__c=10, Woo_Product_Id__c='88002');
        insert p;
        Lead l = new Lead(FirstName='Fail', LastName='Shopper', Company='Online Shopper',
            Email='fail.shopper@example.com', Status='Open - Not Contacted',
            Email_Consent__c=true, Last_Cart_Value__c=60);
        insert l;
        Cart__c cart = new Cart__c(Status__c='Abandoned', Email_Consent__c=true, Lead__c=l.Id,
            Shopper_Email__c='fail.shopper@example.com', Cart_Value__c=60, Item_Count__c=1,
            Woo_Cart_Id__c='fail-cart-1');
        insert cart;
        insert new Cart_Item__c(Cart__c=cart.Id, Product__c=p.Id, Quantity__c=1,
            Unit_Price__c=60, Line_Total__c=60, SKU__c='FAILURE-BEAN');

        wooMockMethods.clear();
        Test.setMock(HttpCalloutMock.class, new WooCouponMock());
        LeadNurtureService.forceEmailFailureInTests = true;
        Test.startTest();
        LeadNurtureService.Result r = LeadNurtureService.run(l.Id);
        Test.stopTest();
        LeadNurtureService.forceEmailFailureInTests = false;

        System.assertEquals(false, r.success, 'email failure should fail honestly');
        System.assert(r.message.contains('Recovery email was not sent'), r.message);
        System.assertEquals('Open - Not Contacted', [SELECT Status FROM Lead WHERE Id=:l.Id].Status,
            'lead must not be marked contacted');
        System.assertEquals(null, [SELECT Recovery_Sent_At__c FROM Cart__c WHERE Id=:cart.Id].Recovery_Sent_At__c,
            'cart must not be marked recovered');
        System.assertEquals(0, [SELECT count() FROM Coupon__c WHERE Code__c=:r.couponCode],
            'Salesforce coupon audit must not be persisted when email failed');
        System.assert(wooMockMethods.contains('DELETE'),
            'Woo coupon should be cleaned up when email fails after coupon creation');
    }

    @isTest
    static void testNoEmail() {
        Lead l = new Lead(LastName='NoEmail', Company='Online Shopper', Status='Open - Not Contacted');
        insert l;
        Test.startTest();
        LeadNurtureService.Result r = LeadNurtureService.run(l.Id);
        Test.stopTest();
        System.assertEquals(false, r.success, 'no email -> fail gracefully');
    }
}
