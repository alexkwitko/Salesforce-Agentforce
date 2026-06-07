@isTest
private class LeadNurtureServiceTest {

    private class WooCouponMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"id":777,"code":"comeback"}');
            return res;
        }
    }

    @isTest
    static void testSendRecovery() {
        Lead l = new Lead(FirstName='Sam', LastName='Shopper', Company='Online Shopper',
            Email='sam.shopper@example.com', Status='Open - Not Contacted',
            Email_Consent__c=true, Last_Cart_Value__c=60);
        insert l;

        Test.setMock(HttpCalloutMock.class, new WooCouponMock());
        Test.startTest();
        LeadNurtureService.Request req = new LeadNurtureService.Request();
        req.leadId = l.Id;
        List<LeadNurtureService.Result> rs = LeadNurtureService.sendRecovery(
            new List<LeadNurtureService.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, rs[0].success, 'should succeed');
        System.assert(rs[0].couponCode.startsWith('COMEBACK'), 'code: ' + rs[0].couponCode);

        Lead l2 = [SELECT Status FROM Lead WHERE Id=:l.Id];
        System.assertEquals('Working - Contacted', l2.Status, 'lead marked contacted');

        Coupon__c c = [SELECT Woo_Coupon_Id__c, Discount_Percent__c FROM Coupon__c WHERE Code__c=:rs[0].couponCode LIMIT 1];
        System.assertEquals('777', c.Woo_Coupon_Id__c, 'woo id captured');
        System.assertEquals(10, c.Discount_Percent__c);
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
