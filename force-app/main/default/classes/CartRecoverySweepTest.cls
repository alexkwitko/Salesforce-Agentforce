@isTest
private class CartRecoverySweepTest {
    private class WooMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) { HttpResponse r=new HttpResponse(); r.setStatusCode(201); r.setBody('{"id":1,"code":"x"}'); return r; }
    }
    @isTest static void testSweep() {
        Product2 p = new Product2(Name='Cara Recovery Bean', Family='Single-Origin', IsActive=true,
            Stock_On_Hand__c=10, Woo_Product_Id__c='88101');
        insert p;
        Lead l = new Lead(FirstName='Cara', LastName='Cart', Company='Online Shopper', Email='cara.cart@example.com',
            Status='Open - Not Contacted', LeadSource='Website Chat', Email_Consent__c=true, Last_Cart_Value__c=48);
        insert l;
        // Abandoned cart linked to a PRE-EXISTING (non-WooCommerce-source) lead — the case the old sweep missed.
        Cart__c c = new Cart__c(Status__c='Abandoned', Email_Consent__c=true, Lead__c=l.Id,
            Shopper_Email__c='cara.cart@example.com', Cart_Value__c=48, Item_Count__c=1, Woo_Cart_Id__c='cara-1');
        insert c;
        insert new Cart_Item__c(Cart__c=c.Id, Product__c=p.Id, Quantity__c=1,
            Unit_Price__c=48, Line_Total__c=48, SKU__c='CARA-RECOVERY-BEAN');
        Test.setMock(HttpCalloutMock.class, new WooMock());
        Test.startTest();
        Integer n = CartRecoverySweep.sweep();
        Test.stopTest();
        System.assertEquals(1, n, 'one eligible abandoned cart -> lead');
        System.assertEquals('Working - Contacted', [SELECT Status FROM Lead WHERE Id=:l.Id].Status, 'lead contacted');
        System.assertEquals(1, [SELECT count() FROM Coupon__c WHERE Code__c LIKE 'COMEBACK%'], 'recovery coupon created');
        System.assertNotEquals(null, [SELECT Recovery_Sent_At__c FROM Cart__c WHERE Id=:c.Id].Recovery_Sent_At__c, 'cart stamped');
        // idempotency: second sweep finds nothing
        System.assertEquals(0, CartRecoverySweep.sweep(), 'already recovered -> skipped');
    }
}
