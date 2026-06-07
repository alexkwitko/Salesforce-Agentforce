/**
 * Tests for WooCommerce → Salesforce account/profile sync (name, consent, address) on update.
 */
@isTest
private class WooCustomerSyncTest {

    @testSetup
    static void setup() {
        insert new Woo_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Webhook_Secret__c = 'topsecret');
    }

    private static Map<String, Object> profile(String email, Boolean consent) {
        return new Map<String, Object>{
            'email' => email, 'first_name' => 'Alex', 'last_name' => 'Kwitko', 'phone' => '202-555-0123',
            'consent' => consent,
            'billing' => new Map<String, Object>{ 'address_1' => '123 Bean St', 'city' => 'Washington',
                                                  'state' => 'DC', 'postcode' => '20001', 'country' => 'US' },
            'shipping' => new Map<String, Object>{ 'address_1' => '500 Roast Ave', 'city' => 'Seattle',
                                                   'state' => 'WA', 'postcode' => '98101', 'country' => 'US' }
        };
    }

    @isTest
    static void testCreatesAndUpdatesPersonAccount() {
        Test.startTest();
        Id id1 = WooCustomerService.upsertProfile(profile('sync.new@example.com', true));
        Test.stopTest();
        Account a = [SELECT FirstName, LastName, Phone, Email_Consent__c, Email_Consent_Date__c,
                            BillingStreet, BillingCity, BillingStateCode, BillingCountryCode,
                            ShippingCity, ShippingStateCode FROM Account WHERE Id = :id1];
        System.assertEquals('Alex', a.FirstName);
        System.assertEquals('Kwitko', a.LastName);
        System.assertEquals('202-555-0123', a.Phone);
        System.assertEquals(true, a.Email_Consent__c);
        System.assertNotEquals(null, a.Email_Consent_Date__c, 'consent date stamped');
        System.assertEquals('Washington', a.BillingCity);
        System.assertEquals('DC', a.BillingStateCode);
        System.assertEquals('US', a.BillingCountryCode);
        System.assertEquals('Seattle', a.ShippingCity);
        System.assertEquals('WA', a.ShippingStateCode);
    }

    @isTest
    static void testHonorsExplicitOptOut() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        insert new Account(RecordTypeId=rt, FirstName='Opt', LastName='Out',
            PersonEmail='optout@example.com', Email_Consent__c=true);
        Test.startTest();
        WooCustomerService.upsertProfile(profile('optout@example.com', false)); // unticked consent on account page
        Test.stopTest();
        // explicit opt-out on the account page IS honored (unlike the checkout never-auto-revoke path)
        System.assertEquals(false, [SELECT Email_Consent__c FROM Account WHERE PersonEmail='optout@example.com'].Email_Consent__c);
    }

    @isTest
    static void testHmacEndpoint() {
        String json = JSON.serialize(profile('hmac.sync@example.com', true));
        Blob b = Blob.valueOf(json);
        String sig = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', b, Blob.valueOf('topsecret')));
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/woo/customer/'; req.httpMethod = 'POST';
        req.requestBody = b; req.headers.put('X-Kwitko-Signature', sig);
        RestContext.request = req; RestContext.response = new RestResponse();
        Test.startTest(); WooCustomerResource.handlePost(); Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE PersonEmail='hmac.sync@example.com']);
    }

    @isTest
    static void testHmacRejectsBad() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(JSON.serialize(profile('x@example.com', true)));
        req.headers.put('X-Kwitko-Signature', 'nope');
        RestContext.request = req; RestContext.response = new RestResponse();
        Test.startTest(); WooCustomerResource.handlePost(); Test.stopTest();
        System.assertEquals(401, RestContext.response.statusCode);
    }
}
