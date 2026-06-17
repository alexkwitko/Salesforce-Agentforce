@isTest
private class CustomerInsightsServiceTest {

    @isTest static void computesValueAndTasteProfile() {
        Id personRt = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(FirstName = 'Insights', LastName = 'Tester',
            PersonEmail = 'insights.tester@example.com', RecordTypeId = personRt);
        insert a;

        Product2 p = new Product2(Name = 'Dark Single Origin', IsActive = true,
            Family = 'Single-Origin', Roast_Level__c = 'Dark',
            Bean_Type__c = 'Single-Origin', Brew_Style__c = 'Espresso',
            Is_Decaf__c = false, Is_Flavored__c = false);
        insert p;

        Id pbId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = pbId, Product2Id = p.Id,
            UnitPrice = 20, IsActive = true);
        insert pbe;

        Order o = new Order(AccountId = a.Id, Status = 'Draft',
            EffectiveDate = Date.today().addDays(-10), Pricebook2Id = pbId);
        insert o;
        insert new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id,
            Quantity = 3, UnitPrice = 20);

        insert new Case(AccountId = a.Id, Status = 'New', Origin = 'Web', Subject = 'Test');

        insert new Web_Event__c(Account__c = a.Id, Device_Id__c = 'dev-1',
            Session_Id__c = 'sess-1', Event_Type__c = 'page_view', Occurred_At__c = System.now());

        Test.startTest();
        String res = CustomerInsightsService.run();
        Test.stopTest();

        Account got = [SELECT Insights_Order_Count__c, Insights_LTV__c, Insights_AOV__c,
                              Insights_Last_Order_Date__c, Insights_Days_Since_Last_Order__c,
                              Insights_RFM_Segment__c, Insights_Lifecycle_Stage__c,
                              Insights_Taste_Profile__c, Insights_Updated__c,
                              Insights_Total_Cases__c, Insights_Open_Cases__c,
                              Insights_Device_Count__c, Insights_Web_Events__c
                       FROM Account WHERE Id = :a.Id];
        System.assertEquals(1, got.Insights_Total_Cases__c, 'total cases');
        System.assertEquals(1, got.Insights_Open_Cases__c, 'open cases');
        System.assertEquals(1, got.Insights_Device_Count__c, 'devices');
        System.assertEquals(1, got.Insights_Web_Events__c, 'web events');
        System.assertEquals(1, got.Insights_Order_Count__c, res);
        System.assertEquals('Active', got.Insights_Lifecycle_Stage__c, 'recency 10d => Active');
        System.assert(got.Insights_Taste_Profile__c != null, 'taste profile set');
        System.assert(got.Insights_Taste_Profile__c.contains('Roast: Dark'),
            got.Insights_Taste_Profile__c);
        System.assertNotEquals(null, got.Insights_Updated__c);
    }

    @isTest static void doesNotDowngradeDataCloudOwnedAccountCache() {
        Id personRt = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(
            FirstName = 'Unified',
            LastName = 'Cache',
            PersonEmail = 'unified.cache@example.com',
            RecordTypeId = personRt,
            Data_Cloud_Unified_Individual_Id__c = 'uid-unified-cache',
            Data_Cloud_Insight_Source__c = 'Data Cloud Unified CI + CRM fallback',
            Insights_Order_Count__c = 7,
            Insights_LTV__c = 886.10,
            Insights_Web_Events__c = 148,
            Insights_Device_Count__c = 6,
            Insights_Session_Count__c = 17,
            Insights_Total_Cases__c = 21
        );
        insert a;

        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name = 'Local CRM Product', IsActive = true, Family = 'Coffee');
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = p.Id,
            UnitPrice = 20,
            IsActive = true
        );
        insert pbe;
        Order o = new Order(
            AccountId = a.Id,
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = pbId
        );
        insert o;
        insert new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 20);
        insert new Case(AccountId = a.Id, Status = 'New', Origin = 'Web', Subject = 'Local case');
        insert new Web_Event__c(
            Account__c = a.Id,
            Device_Id__c = 'legacy-dev',
            Session_Id__c = 'legacy-sess',
            Event_Type__c = 'page_view',
            Occurred_At__c = System.now()
        );

        Test.startTest();
        CustomerInsightsService.run();
        Test.stopTest();

        Account got = [
            SELECT Insights_Order_Count__c, Insights_LTV__c, Insights_Web_Events__c,
                   Insights_Device_Count__c, Insights_Session_Count__c, Insights_Total_Cases__c,
                   Data_Cloud_Insight_Source__c
            FROM Account
            WHERE Id = :a.Id
        ];
        System.assertEquals(7, got.Insights_Order_Count__c.intValue(), 'CRM fallback job must not overwrite unified order count');
        System.assertEquals(886.10, got.Insights_LTV__c, 'CRM fallback job must not overwrite unified LTV');
        System.assertEquals(148, got.Insights_Web_Events__c.intValue(), 'CRM fallback job must not overwrite SDK web count');
        System.assertEquals(6, got.Insights_Device_Count__c.intValue(), 'CRM fallback job must not overwrite SDK device count');
        System.assertEquals(17, got.Insights_Session_Count__c.intValue(), 'CRM fallback job must not overwrite SDK session count');
        System.assertEquals(21, got.Insights_Total_Cases__c.intValue(), 'CRM fallback job must not overwrite unified service case count');
        System.assertEquals('Data Cloud Unified CI + CRM fallback', got.Data_Cloud_Insight_Source__c);
    }

    @isTest static void segmentationRules() {
        System.assertEquals('Champion', CustomerInsightsService.rfm(10, 5, 500));
        System.assertEquals('Loyal', CustomerInsightsService.rfm(10, 4, 50));
        System.assertEquals('Big Spender', CustomerInsightsService.rfm(10, 1, 300));
        System.assertEquals('Promising', CustomerInsightsService.rfm(20, 1, 20));
        System.assertEquals('Hibernating', CustomerInsightsService.rfm(400, 1, 20));
        System.assertEquals('No Purchases', CustomerInsightsService.rfm(null, 0, 0));
        System.assertEquals('Lapsed', CustomerInsightsService.lifecycle(300));
        System.assertEquals('Unknown', CustomerInsightsService.lifecycle(null));
    }

    @isTest static void schedules() {
        Test.startTest();
        String id = CustomerInsightsService.scheduleDaily();
        Test.stopTest();
        System.assertNotEquals(null, id);
    }
}
