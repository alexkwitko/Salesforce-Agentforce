@isTest
private class JourneyServiceTest {

    @isTest
    static void testRecordPurchaseAndState() {
        Account a = new Account(Name = 'Test Co');
        insert a;
        Product2 p1 = new Product2(Name = 'Beans A', IsActive = true);
        Product2 p2 = new Product2(Name = 'Beans B', IsActive = true);
        insert new List<Product2>{ p1, p2 };

        Test.startTest();
        JourneyService.recordPurchase('buyer@example.com', a.Id, new List<Id>{ p1.Id, p2.Id }, null);
        JourneyService.StateRequest req = new JourneyService.StateRequest();
        req.email = 'buyer@example.com';
        List<JourneyService.State> states = JourneyService.getJourneyState(new List<JourneyService.StateRequest>{ req });
        Test.stopTest();

        JourneyService.State s = states[0];
        System.assertEquals(true, s.found, 'journey should exist');
        System.assertEquals(true, s.isReturning, 'has purchases => returning');
        System.assert(s.purchasedProductIds.contains(p1.Id), 'p1 recorded');
        System.assert(s.purchasedProductIds.contains(p2.Id), 'p2 recorded');
        System.assertEquals(1, [SELECT count() FROM Customer_Journey__c WHERE Email__c = 'buyer@example.com']);
        System.assertEquals(1, [SELECT count() FROM Agent_Interaction__c WHERE Action__c = 'purchase']);
    }

    @isTest
    static void testLogInteractionAndIdempotencyFields() {
        JourneyService.recordPurchase('shopper@example.com', null, new List<Id>(), null);

        JourneyLogger.LogRequest r = new JourneyLogger.LogRequest();
        r.email = 'shopper@example.com';
        r.agent = 'Post_Purchase_Growth';
        r.action = 'post_purchase_offer';
        r.addRecommendedProductIds = '001000000000001AAA,001000000000002AAA';
        r.markPostPurchaseDoneOrderId = '801000000000001AAA';
        r.stage = 'Post-Purchase';
        r.result = 'coupon sent';

        Test.startTest();
        JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ r });
        Test.stopTest();

        Customer_Journey__c j = [SELECT Recommended_Product_Ids__c, Post_Purchase_Done_Order_Ids__c, Last_Stage__c, Last_Agent__c
                                 FROM Customer_Journey__c WHERE Email__c = 'shopper@example.com' LIMIT 1];
        System.assert(j.Recommended_Product_Ids__c.contains('001000000000001AAA'));
        System.assert(j.Post_Purchase_Done_Order_Ids__c.contains('801000000000001AAA'));
        System.assertEquals('Post-Purchase', j.Last_Stage__c);
        System.assertEquals('Post_Purchase_Growth', j.Last_Agent__c);
    }

    @isTest
    static void testUnknownEmail() {
        JourneyService.StateRequest req = new JourneyService.StateRequest();
        req.email = 'nobody@example.com';
        List<JourneyService.State> states = JourneyService.getJourneyState(new List<JourneyService.StateRequest>{ req });
        System.assertEquals(false, states[0].found);
        System.assertEquals(false, states[0].isReturning);
    }

    @isTest
    static void testGetOrCreateToleratesDuplicateEmail() {
        // A journey already exists; a second getOrCreate with a case/space-variant email must NOT throw
        // the DUPLICATE_VALUE that previously broke the calling agent action — it returns the existing one.
        insert new Customer_Journey__c(Name='dup@example.com', Email__c='dup@example.com');
        Test.startTest();
        Customer_Journey__c j = JourneyService.getOrCreate('  Dup@example.com  ', null, null);
        Test.stopTest();
        System.assertNotEquals(null, j, 'returns a journey, never throws');
        System.assertEquals(1, [SELECT COUNT() FROM Customer_Journey__c WHERE Email__c='dup@example.com'], 'no duplicate created');
    }
}
