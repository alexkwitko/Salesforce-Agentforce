@isTest
private class CustomerPreferenceServiceTest {

    private static Account makePersonAccount(String email) {
        Id rt = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(LastName = 'Prefs', PersonEmail = email, RecordTypeId = rt);
        insert a;
        return a;
    }

    @isTest
    static void savesAndMergesPreferences() {
        Account a = makePersonAccount('preftest@example.com');

        CustomerPreferenceService.Request r1 = new CustomerPreferenceService.Request();
        r1.email = 'preftest@example.com';
        r1.dislikeItem = 'decaf';
        r1.roast = 'medium';
        r1.format = 'whole bean';
        r1.brew = 'espresso';

        Test.startTest();
        List<CustomerPreferenceService.Result> res1 = CustomerPreferenceService.save(
            new List<CustomerPreferenceService.Request>{ r1 });
        // second call merges a like without wiping the dislike
        CustomerPreferenceService.Request r2 = new CustomerPreferenceService.Request();
        r2.email = 'preftest@example.com';
        r2.likeItem = 'single-origin';
        r2.notes = 'prefers bright acidity';
        List<CustomerPreferenceService.Result> res2 = CustomerPreferenceService.save(
            new List<CustomerPreferenceService.Request>{ r2 });
        Test.stopTest();

        System.assert(res1[0].success, 'first save should succeed');
        System.assert(res1[0].preferencesJson.toLowerCase().contains('decaf'), 'dislike persisted');
        System.assert(res2[0].preferencesJson.toLowerCase().contains('single-origin'), 'like merged');
        System.assert(res2[0].preferencesJson.toLowerCase().contains('decaf'), 'dislike retained after merge');

        Account after = [SELECT Coffee_Preferences__c FROM Account WHERE Id = :a.Id];
        System.assert(after.Coffee_Preferences__c.toLowerCase().contains('espresso'), 'brew saved on account');

        // blank email path
        CustomerPreferenceService.Request blank = new CustomerPreferenceService.Request();
        System.assertEquals(false, CustomerPreferenceService.save(
            new List<CustomerPreferenceService.Request>{ blank })[0].success);
    }

    @isTest
    static void lookupReturningCustomerWithOrders() {
        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name = 'SO Test 12oz', Family = 'Single-Origin', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = pbId, Product2Id = p.Id, UnitPrice = 18, IsActive = true);
        insert pbe;
        Account a = makePersonAccount('buyer@example.com');
        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = pbId);
        insert o;
        insert new OrderItem(OrderId = o.Id, Product2Id = p.Id, PricebookEntryId = pbe.Id, Quantity = 2, UnitPrice = 18);

        CustomerLookupService.Request req = new CustomerLookupService.Request();
        req.email = 'buyer@example.com';
        req.verifiedEmail = 'buyer@example.com'; // verified identity unlocks order/LTV PII
        Test.startTest();
        List<CustomerLookupService.Result> out = CustomerLookupService.lookup(
            new List<CustomerLookupService.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, out[0].isReturning, 'has an order → returning');
        System.assertEquals(1, out[0].orderCount, 'one order');
        System.assertEquals('Single-Origin', out[0].favoriteCategory, 'favorite category from order items');
    }

    @isTest
    static void lookupReturnsPreferences() {
        Account a = makePersonAccount('lookuppref@example.com');
        a.Coffee_Preferences__c = '{"dislikes":["decaf"],"roast":"medium"}';
        update a;

        CustomerLookupService.Request req = new CustomerLookupService.Request();
        req.email = 'lookuppref@example.com';

        Test.startTest();
        List<CustomerLookupService.Result> out = CustomerLookupService.lookup(
            new List<CustomerLookupService.Request>{ req });
        // blank-email branch for coverage
        CustomerLookupService.Request b = new CustomerLookupService.Request();
        b.email = '';
        CustomerLookupService.lookup(new List<CustomerLookupService.Request>{ b });
        // no-account-on-file branch (new prospect)
        CustomerLookupService.Request noacc = new CustomerLookupService.Request();
        noacc.email = 'noaccount-' + Math.abs(Crypto.getRandomInteger()) + '@example.com';
        List<CustomerLookupService.Result> np = CustomerLookupService.lookup(
            new List<CustomerLookupService.Request>{ noacc });
        Test.stopTest();
        System.assertEquals(false, np[0].isReturning, 'unknown email → not returning');

        System.assert(out[0].preferences != null, 'preferences returned');
        System.assert(out[0].preferences.toLowerCase().contains('decaf'), 'dislike surfaced to agent');
        System.assert(out[0].summary.toLowerCase().contains('preferences'), 'summary flags saved preferences');
    }
}
