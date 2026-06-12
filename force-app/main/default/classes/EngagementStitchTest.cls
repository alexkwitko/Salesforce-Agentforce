@isTest
private class EngagementStitchTest {

    private static Web_Event__c ev(String device, String type, String pageUrl) {
        return new Web_Event__c(Device_Id__c=device, Session_Id__c=device+'-s',
            Event_Type__c=type, Page_Url__c=pageUrl, Occurred_At__c=System.now());
    }

    // Anonymous browse on one device, then identify -> all that device's anon events cross to the person.
    @isTest static void testAnonymousThenIdentify() {
        String dev = 'browserA-uuid-1';
        EngagementIngestService.ingest(new List<Web_Event__c>{
            ev(dev,'pageView','/'), ev(dev,'catalog','/product/ethiopia'), ev(dev,'pageEngagement','/product/ethiopia') });
        // pre: all anonymous
        System.assertEquals(3, [SELECT COUNT() FROM Web_Event__c WHERE Device_Id__c=:dev AND Account__c=null]);

        Test.startTest();
        Id acct = IdentityStitchService.stitch(dev, 'Maria@Test.com', 'Maria', 'Coffee');
        Test.stopTest();

        System.assertNotEquals(null, acct, 'account created/resolved');
        System.assertEquals(0, [SELECT COUNT() FROM Web_Event__c WHERE Device_Id__c=:dev AND Account__c=null],
            'no anonymous events left for the device');
        System.assertEquals(3, [SELECT COUNT() FROM Web_Event__c WHERE Account__c=:acct],
            'all 3 anonymous events now crossed to the person');
        Account a = [SELECT PersonEmail FROM Account WHERE Id=:acct];
        System.assertEquals('maria@test.com', a.PersonEmail, 'email lowercased + matched');
    }

    // MULTI-BROWSER: two devices browse anonymously; identify the SAME email on each ->
    // both browsers' device ids + anonymous history collapse to ONE person (cross-device).
    @isTest static void testCrossDeviceMultiBrowser() {
        String laptop = 'browser-laptop-AAA';
        String phone  = 'browser-phone-BBB';
        EngagementIngestService.ingest(new List<Web_Event__c>{
            ev(laptop,'pageView','/'), ev(laptop,'catalog','/product/ethiopia') });
        EngagementIngestService.ingest(new List<Web_Event__c>{
            ev(phone,'pageView','/sale'), ev(phone,'cart','/cart'), ev(phone,'checkout','/checkout') });

        Test.startTest();
        Id a1 = IdentityStitchService.stitch(laptop, 'same@person.com', 'Sam', 'Buyer'); // logs in on laptop
        Id a2 = IdentityStitchService.stitch(phone,  'same@person.com', 'Sam', 'Buyer'); // later logs in on phone
        Test.stopTest();

        System.assertEquals(a1, a2, 'same person across both browsers');
        System.assertEquals(5, [SELECT COUNT() FROM Web_Event__c WHERE Account__c=:a1],
            'all 5 events from BOTH browsers crossed to the one person');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE PersonEmail='same@person.com'],
            'exactly one person account');
        // both distinct device ids now tie to the same account
        System.assertEquals(2, [SELECT Device_Id__c FROM Web_Event__c
            WHERE Account__c=:a1 GROUP BY Device_Id__c].size(), 'two devices unified under one person');
    }

    // Not-logged-in users stay anonymous (privacy): no identify -> Account stays null.
    @isTest static void testNotLoggedStaysAnonymous() {
        String dev = 'browser-guest-CCC';
        EngagementIngestService.ingest(new List<Web_Event__c>{ ev(dev,'pageView','/'), ev(dev,'catalog','/p/x') });
        System.assertEquals(2, [SELECT COUNT() FROM Web_Event__c WHERE Device_Id__c=:dev AND Account__c=null],
            'guest browsing remains anonymous until they identify');
    }

    // Existing customer: identify links to the EXISTING person account, not a duplicate.
    @isTest static void testExistingCustomer() {
        Id rt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account existing = new Account(RecordTypeId=rt, FirstName='Old', LastName='Customer', PersonEmail='existing@test.com');
        insert existing;
        String dev = 'browser-known-DDD';
        EngagementIngestService.ingest(new List<Web_Event__c>{ ev(dev,'pageView','/') });

        Test.startTest();
        Id acct = IdentityStitchService.stitch(dev, 'existing@test.com', 'Old', 'Customer');
        Test.stopTest();

        System.assertEquals(existing.Id, acct, 'linked to the existing customer, no duplicate');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE PersonEmail='existing@test.com']);
    }

    // REST endpoint: batch of anon events + identify in one POST.
    @isTest static void testRest() {
        String body = '{"deviceId":"rest-dev-EEE","sessionId":"s1","events":['
            + '{"type":"pageView","pageUrl":"/"},'
            + '{"type":"catalog","productId":"77","productName":"Ethiopia","timeOnPage":92,"scrollPct":100}],'
            + '"identify":{"email":"rest@test.com","firstName":"Rest","lastName":"User"}}';
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/engagement';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        String out = EngagementRest.post();
        Test.stopTest();

        System.assert(out.contains('"ok":true'), 'rest ok');
        Id acct = [SELECT Id FROM Account WHERE PersonEmail='rest@test.com' LIMIT 1].Id;
        System.assertEquals(2, [SELECT COUNT() FROM Web_Event__c WHERE Account__c=:acct],
            'both posted events stored + crossed to the person');
    }
}
