@isTest
private class Chat_Nurture_SweepTest {
    private class WooMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":12345,"code":"CHATNURT1"}');
            return res;
        }
    }
    @isTest
    static void testSweepFindsChatLeads() {
        Lead chat = new Lead(LastName='ChatLead', Company='Consumer', Email='nurtureme@example.com',
            LeadSource='Website Chat', Status='Open - Not Contacted', Email_Consent__c=true);
        Lead noConsent = new Lead(LastName='NoConsent', Company='Consumer', Email='nc2@example.com',
            LeadSource='Website Chat', Status='Open - Not Contacted', Email_Consent__c=false);
        insert new List<Lead>{ chat, noConsent };

        Test.setMock(HttpCalloutMock.class, new WooMock());
        Test.startTest();
        Integer count = Chat_Nurture_Sweep.sweep();
        Test.stopTest();

        System.assertEquals(1, count, 'only the consenting chat lead qualifies');
    }
}
