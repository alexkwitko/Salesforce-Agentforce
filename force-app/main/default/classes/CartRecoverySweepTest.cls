@isTest
private class CartRecoverySweepTest {
    private class WooMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) { HttpResponse r=new HttpResponse(); r.setStatusCode(201); r.setBody('{"id":1,"code":"x"}'); return r; }
    }
    @isTest static void testSweep() {
        Lead l = new Lead(FirstName='Cara', LastName='Cart', Company='Online Shopper', Email='cara.cart@example.com',
            Status='Open - Not Contacted', LeadSource='WooCommerce Abandoned Cart', Email_Consent__c=true, Last_Cart_Value__c=48);
        insert l;
        Test.setMock(HttpCalloutMock.class, new WooMock());
        Test.startTest();
        Integer n = CartRecoverySweep.sweep();
        Test.stopTest();
        System.assertEquals(1, n, 'one eligible lead');
        System.assertEquals('Working - Contacted', [SELECT Status FROM Lead WHERE Id=:l.Id].Status, 'lead contacted');
        System.assertEquals(1, [SELECT count() FROM Coupon__c WHERE Code__c LIKE 'COMEBACK%'], 'recovery coupon created');
    }
}
