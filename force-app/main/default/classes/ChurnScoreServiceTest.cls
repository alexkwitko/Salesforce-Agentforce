@isTest
private class ChurnScoreServiceTest {

    private static Id personRt() {
        return [SELECT Id FROM RecordType
                WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
    }

    private static Account makeBuyer(String last, Boolean consent) {
        Account a = new Account(RecordTypeId = personRt(), FirstName='T', LastName=last,
            PersonEmail = last + '@test.com', Email_Consent__c = consent);
        insert a;
        return [SELECT Id, PersonContactId FROM Account WHERE Id=:a.Id];
    }

    // creates an order dated daysAgo with the given amount (via one order item)
    private static void addOrder(Id acctId, Id pbeId, Id pbId, Integer daysAgo, Decimal amt) {
        Order o = new Order(AccountId=acctId, EffectiveDate=Date.today().addDays(-daysAgo),
            Status='Draft', Pricebook2Id=pbId);
        insert o;
        insert new OrderItem(OrderId=o.Id, PricebookEntryId=pbeId, Quantity=1, UnitPrice=amt);
    }

    @isTest static void testScoring() {
        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Coffee', IsActive=true); insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id=pbId, Product2Id=p.Id, UnitPrice=50, IsActive=true);
        insert pbe;

        // lapsed high-value buyer: 6 orders of ~$120 spanning a year, last 200 days ago
        Account hi = makeBuyer('Lapsed', true);
        for (Integer i=0; i<6; i++) addOrder(hi.Id, pbe.Id, pbId, 200 + i*70, 120);

        // recent active buyer: 4 orders, last one 10 days ago
        Account lo = makeBuyer('Active', true);
        for (Integer i=0; i<4; i++) addOrder(lo.Id, pbe.Id, pbId, 10 + i*30, 40);

        Test.startTest();
        Integer n = ChurnScoreService.scoreAll();
        Test.stopTest();

        System.assert(n >= 2, 'should score at least the two buyers');
        Account hiScored = [SELECT Churn_Score__c, Predicted_LTV__c, Churn_Risk_Tier__c,
                                   Value_At_Risk__c, Last_Scored__c FROM Account WHERE Id=:hi.Id];
        Account loScored = [SELECT Churn_Score__c, Predicted_LTV__c FROM Account WHERE Id=:lo.Id];

        System.assertNotEquals(null, hiScored.Churn_Score__c, 'churn scored');
        System.assertNotEquals(null, hiScored.Predicted_LTV__c, 'ltv scored');
        System.assertNotEquals(null, hiScored.Last_Scored__c, 'timestamped');
        System.assert(hiScored.Churn_Score__c > loScored.Churn_Score__c,
            'lapsed buyer must be riskier than the active buyer');
        System.assert(hiScored.Predicted_LTV__c > 0, 'lapsed buyer has predicted value');
        System.assertNotEquals(null, hiScored.Churn_Risk_Tier__c, 'tier assigned');
    }

    @isTest static void testWebEngagementDamper() {
        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Coffee', IsActive=true); insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id=pbId, Product2Id=p.Id, UnitPrice=50, IsActive=true);
        insert pbe;

        // two identical lapsed buyers...
        Account quiet    = makeBuyer('QuietLapsed', true);
        Account browsing = makeBuyer('BrowsingLapsed', true);
        for (Integer i=0; i<6; i++) {
            addOrder(quiet.Id, pbe.Id, pbId, 200 + i*70, 120);
            addOrder(browsing.Id, pbe.Id, pbId, 200 + i*70, 120);
        }
        // ...but one was on the website yesterday (3 stitched events)
        List<Web_Event__c> evs = new List<Web_Event__c>();
        for (Integer i=0; i<3; i++) {
            evs.add(new Web_Event__c(Account__c = browsing.Id, Device_Id__c = 'TESTDEV',
                Event_Type__c = 'pageView', Occurred_At__c = System.now().addDays(-1)));
        }
        insert evs;

        Test.startTest();
        ChurnScoreService.scoreAll();
        Test.stopTest();

        Account q = [SELECT Churn_Score__c, Web_Events_30d__c, Web_Last_Seen__c FROM Account WHERE Id=:quiet.Id];
        Account b = [SELECT Churn_Score__c, Web_Events_30d__c, Web_Last_Seen__c FROM Account WHERE Id=:browsing.Id];

        System.assert(b.Churn_Score__c < q.Churn_Score__c,
            'recently-browsing lapsed buyer must score lower churn than the silent one');
        System.assertEquals(3, b.Web_Events_30d__c, 'web event count written');
        System.assertNotEquals(null, b.Web_Last_Seen__c, 'web last-seen written');
        System.assertEquals(0, q.Web_Events_30d__c, 'no web activity -> zero');
    }

    @isTest static void testDataCloudAccountWebInsightsDamperWithoutLegacyEvents() {
        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Coffee', IsActive=true); insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id=pbId, Product2Id=p.Id, UnitPrice=50, IsActive=true);
        insert pbe;

        Account quiet = makeBuyer('QuietSdkLapsed', true);
        Account browsing = makeBuyer('BrowsingSdkLapsed', true);
        for (Integer i=0; i<6; i++) {
            addOrder(quiet.Id, pbe.Id, pbId, 200 + i*70, 120);
            addOrder(browsing.Id, pbe.Id, pbId, 200 + i*70, 120);
        }
        update new Account(
            Id = browsing.Id,
            Insights_Web_Events__c = 12,
            Insights_Last_Web_Activity__c = System.now().addDays(-1)
        );

        Test.startTest();
        ChurnScoreService.scoreAll();
        Test.stopTest();

        Account q = [SELECT Churn_Score__c, Web_Events_30d__c, Web_Last_Seen__c FROM Account WHERE Id=:quiet.Id];
        Account b = [SELECT Churn_Score__c, Web_Events_30d__c, Web_Last_Seen__c FROM Account WHERE Id=:browsing.Id];

        System.assert(b.Churn_Score__c < q.Churn_Score__c,
            'Data Cloud SDK web activity must dampen churn even when Web_Event__c is empty');
        System.assertEquals(12, b.Web_Events_30d__c, 'SDK web event count written to operational web count');
        System.assertNotEquals(null, b.Web_Last_Seen__c, 'SDK web last-seen written');
        System.assertEquals(0, q.Web_Events_30d__c, 'silent customer remains without web signal');
    }

    @isTest static void testEngagementOnlyVisitor() {
        // a stitched visitor with web events but NO orders still gets web fields
        Account visitor = makeBuyer('VisitorOnly', false);
        insert new Web_Event__c(Account__c = visitor.Id, Device_Id__c = 'TESTDEV2',
            Event_Type__c = 'catalog', Occurred_At__c = System.now());

        Test.startTest();
        Integer n = ChurnScoreService.scoreAll();
        Test.stopTest();

        System.assert(n >= 1, 'visitor counted');
        Account v = [SELECT Churn_Score__c, Web_Events_30d__c FROM Account WHERE Id=:visitor.Id];
        System.assertEquals(1, v.Web_Events_30d__c, 'visitor web count written');
        System.assertEquals(null, v.Churn_Score__c, 'no orders -> no churn score');
    }

    @isTest static void testNoOrders() {
        Test.startTest();
        Integer n = ChurnScoreService.scoreAll();
        Test.stopTest();
        System.assertEquals(0, n, 'no orders -> nothing scored');
    }

    @isTest static void testScheduler() {
        Test.startTest();
        String cron = '0 0 2 * * ?';
        System.schedule('ChurnScoreTest', cron, new ChurnScoreService.Scheduler());
        Test.stopTest();
    }
}
