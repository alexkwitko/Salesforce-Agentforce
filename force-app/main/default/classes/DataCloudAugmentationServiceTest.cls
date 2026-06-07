@isTest
private class DataCloudAugmentationServiceTest {
    @isTest
    static void refreshAccountCachesAgentInsights() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Id pb = Test.getStandardPricebookId();
        Product2 bean = new Product2(Name='Insight Espresso', Family='Espresso', IsActive=true, Woo_Product_Id__c='91001');
        Product2 gear = new Product2(Name='Insight Filter', Family='Filters', IsActive=true, Woo_Product_Id__c='91002');
        insert new List<Product2>{ bean, gear };
        PricebookEntry beanPbe = new PricebookEntry(Pricebook2Id=pb, Product2Id=bean.Id, UnitPrice=35, IsActive=true);
        PricebookEntry gearPbe = new PricebookEntry(Pricebook2Id=pb, Product2Id=gear.Id, UnitPrice=20, IsActive=true);
        insert new List<PricebookEntry>{ beanPbe, gearPbe };

        Account a = new Account(RecordTypeId=rt, FirstName='Data', LastName='Cloud',
            PersonEmail='dc.customer@example.com', Customer_Status__c='Customer', Return_Count__c=1);
        insert a;
        Order o1 = new Order(AccountId=a.Id, EffectiveDate=Date.today().addDays(-5), Status='Draft', Pricebook2Id=pb);
        Order o2 = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb);
        insert new List<Order>{ o1, o2 };
        insert new List<OrderItem>{
            new OrderItem(OrderId=o1.Id, Product2Id=bean.Id, PricebookEntryId=beanPbe.Id, Quantity=2, UnitPrice=35),
            new OrderItem(OrderId=o2.Id, Product2Id=gear.Id, PricebookEntryId=gearPbe.Id, Quantity=1, UnitPrice=20)
        };

        Test.startTest();
        DataCloudAugmentationService.refreshAccount(a.Id);
        Test.stopTest();

        Account refreshed = [SELECT Data_Cloud_Order_Count__c, Data_Cloud_Lifetime_Value__c,
                             Data_Cloud_Favorite_Category__c, Data_Cloud_Return_Count__c,
                             Data_Cloud_Segment__c, Data_Cloud_Churn_Risk__c,
                             Data_Cloud_Next_Best_Action__c, Data_Cloud_Last_Augmented_At__c
                             FROM Account WHERE Id = :a.Id];
        System.assertEquals(2, refreshed.Data_Cloud_Order_Count__c.intValue());
        System.assertEquals(Decimal.valueOf(90), refreshed.Data_Cloud_Lifetime_Value__c);
        System.assertEquals('Espresso', refreshed.Data_Cloud_Favorite_Category__c);
        System.assertEquals(1, refreshed.Data_Cloud_Return_Count__c.intValue());
        System.assertEquals('Occasional', refreshed.Data_Cloud_Segment__c);
        System.assertEquals('Medium', refreshed.Data_Cloud_Churn_Risk__c);
        System.assert(refreshed.Data_Cloud_Next_Best_Action__c != null);
        System.assertNotEquals(null, refreshed.Data_Cloud_Last_Augmented_At__c);
    }

    @isTest
    static void unverifiedEmailDoesNotRefreshOrReturnPrivateContext() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='Private', LastName='Context',
            PersonEmail='private.dc@example.com');
        insert a;

        DataCloudAugmentationService.Request r = new DataCloudAugmentationService.Request();
        r.email = 'private.dc@example.com';
        r.updateAccount = true;

        Test.startTest();
        DataCloudAugmentationService.Result res = DataCloudAugmentationService.refresh(
            new List<DataCloudAugmentationService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assertEquals(false, res.identityVerified);
        Account unchanged = [SELECT Data_Cloud_Last_Augmented_At__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(null, unchanged.Data_Cloud_Last_Augmented_At__c);
    }

    @isTest
    static void refreshUsesDataCloudCalculatedInsightRowsWhenAvailable() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='Unified', LastName='Profile',
            PersonEmail='unified.profile@example.com');
        insert a;

        DataCloudAugmentationService.testRowsBySqlToken = new Map<String, List<Object>>{
            'ssot__ContactPointEmail__dlm' => new List<Object>{ 'unified.profile@example.com', 'uid-123', 'Unified', '{"roast":"medium"}' },
            'Customer_Agent_Profile__cio' => new List<Object>{ String.valueOf(a.Id), 5, 410, 82, String.valueOf(Date.today()) },
            'Customer_Category_Affinity__cio' => new List<Object>{ 'Espresso', 5 },
            'Customer_Return_Risk__cio' => new List<Object>{ 2, String.valueOf(Date.today()) }
        };
        DataCloudAugmentationService.Request r = new DataCloudAugmentationService.Request();
        r.accountId = String.valueOf(a.Id);
        r.refreshFromDataCloud = true;
        r.updateAccount = true;

        Test.startTest();
        DataCloudAugmentationService.Result res = DataCloudAugmentationService.refresh(
            new List<DataCloudAugmentationService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.success);
        System.assertEquals('uid-123', res.unifiedIndividualId);
        System.assertEquals('Lapsed', res.segment);
        System.assertEquals('High', res.churnRisk);
        System.assertEquals('Data Cloud CI + CRM fallback', res.insightSource);
        System.assertEquals('Espresso', res.favoriteCategory);

        Account refreshed = [SELECT Data_Cloud_Unified_Individual_Id__c, Data_Cloud_Order_Count__c,
                             Data_Cloud_Lifetime_Value__c, Data_Cloud_Favorite_Category__c,
                             Data_Cloud_Return_Count__c, Data_Cloud_Insight_Source__c
                             FROM Account WHERE Id = :a.Id];
        System.assertEquals('uid-123', refreshed.Data_Cloud_Unified_Individual_Id__c);
        System.assertEquals(5, refreshed.Data_Cloud_Order_Count__c.intValue());
        System.assertEquals(Decimal.valueOf(410), refreshed.Data_Cloud_Lifetime_Value__c);
        System.assertEquals('Espresso', refreshed.Data_Cloud_Favorite_Category__c);
        System.assertEquals(2, refreshed.Data_Cloud_Return_Count__c.intValue());
        System.assertEquals('Data Cloud CI + CRM fallback', refreshed.Data_Cloud_Insight_Source__c);
    }
}
