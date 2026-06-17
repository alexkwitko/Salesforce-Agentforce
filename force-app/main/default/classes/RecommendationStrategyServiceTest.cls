@isTest
private class RecommendationStrategyServiceTest {

    private static Product2 mkProd(String name, String family) {
        return new Product2(Name = name, Family = family, IsActive = true,
            Stock_On_Hand__c = 50, Woo_Product_Id__c = String.valueOf(Math.abs(name.hashCode())));
    }

    @testSetup
    static void setup() {
        // products: two beans + one gear
        Product2 beanA = mkProd('Bean A Single', 'Single-Origin');
        Product2 beanB = mkProd('Bean B Single', 'Single-Origin');
        Product2 grinder = mkProd('Hand Grinder', 'Grinders');
        insert new List<Product2>{ beanA, beanB, grinder };

        Id stdPb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : new List<Product2>{ beanA, beanB, grinder }) {
            pbes.add(new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 20, IsActive = true));
        }
        insert pbes;
        Map<Id, PricebookEntry> byProd = new Map<Id, PricebookEntry>();
        for (PricebookEntry e : pbes) byProd.put(e.Product2Id, e);

        Id personRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;

        // customer 1 (the subject) bought beanA
        Account a1 = new Account(RecordTypeId = personRt, FirstName = 'Reco', LastName = 'Tester', PersonEmail = 'reco@example.com');
        // customer 2 bought beanB + grinder (gives best-seller + co-purchase signal)
        Account a2 = new Account(RecordTypeId = personRt, FirstName = 'Other', LastName = 'Buyer', PersonEmail = 'other@example.com');
        insert new List<Account>{ a1, a2 };

        Order o1 = new Order(AccountId = a1.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = stdPb);
        Order o2 = new Order(AccountId = a2.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = stdPb);
        insert new List<Order>{ o1, o2 };

        insert new List<OrderItem>{
            new OrderItem(OrderId = o1.Id, Product2Id = beanA.Id, PricebookEntryId = byProd.get(beanA.Id).Id, Quantity = 2, UnitPrice = 20),
            new OrderItem(OrderId = o2.Id, Product2Id = beanB.Id, PricebookEntryId = byProd.get(beanB.Id).Id, Quantity = 5, UnitPrice = 20),
            new OrderItem(OrderId = o2.Id, Product2Id = grinder.Id, PricebookEntryId = byProd.get(grinder.Id).Id, Quantity = 3, UnitPrice = 20)
        };
    }

    @isTest
    static void testRecurrentStrategyExcludesPurchased() {
        Id beanAId = [SELECT Id FROM Product2 WHERE Name = 'Bean A Single' LIMIT 1].Id;
        Id o1 = [SELECT Id FROM Order WHERE Account.PersonEmail = 'reco@example.com' LIMIT 1].Id;

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'post_purchase';
        req.orderId = o1;

        Test.startTest();
        List<RecommendationStrategyService.Result> rs =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req });
        Test.stopTest();

        RecommendationStrategyService.Result r = rs[0];
        System.assertEquals(true, r.success, r.summary);
        System.assertEquals('Occasional', r.buyerType, '1 purchase in last 12mo, low LTV => Occasional');
        System.assertEquals(1, r.purchasesLast12Mo, 'trailing-12-month purchase count surfaced');
        System.assertNotEquals(beanAId, r.primaryProductId, 'must NOT recommend the purchased bean');
        System.assertEquals(15, r.discountPercent, 'Occasional/post_purchase = 15% (matrix)');
        System.assert(String.isNotBlank(r.packetJson), 'packet json present');
        System.assert(r.packetJson.contains('"unitPrice":20'), 'packet json carries grounded unit prices');
        System.assert(r.summary.contains('$20.00'), 'summary carries grounded price when available');
    }

    @isTest
    static void testBuyerSegmentationPolicy() {
        // Pure policy check: less recurrent => classified for a bigger discount; recurrence by 12-mo + LTV.
        System.assertEquals('New',        RecommendationStrategyService.classifyBuyer(0, 0,   0), 'no history');
        System.assertEquals('Lapsed',     RecommendationStrategyService.classifyBuyer(4, 200, 0), 'bought before, 0 in 12mo');
        System.assertEquals('Occasional', RecommendationStrategyService.classifyBuyer(6, 120, 2), '1-2 in 12mo');
        System.assertEquals('Recurrent',  RecommendationStrategyService.classifyBuyer(6, 120, 3), '3-4 in 12mo');
        System.assertEquals('VIP',        RecommendationStrategyService.classifyBuyer(6, 120, 5), '5+ in 12mo');
        System.assertEquals('VIP',        RecommendationStrategyService.classifyBuyer(2, 400, 2), 'high LTV => VIP');
    }

    @isTest
    static void testNewBuyerAggressiveDiscount() {
        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'brandnew@example.com';   // no account/orders => New
        req.channel = 'abandoned_cart';

        Test.startTest();
        List<RecommendationStrategyService.Result> rs =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req });
        Test.stopTest();

        RecommendationStrategyService.Result r = rs[0];
        System.assertEquals('New', r.buyerType);
        System.assertEquals(25, r.discountPercent, 'New/abandoned_cart = 25% (matrix)');
        System.assert(r.success, r.summary);
    }

    @isTest
    static void testAnonymousChatRecommendationDoesNotNeedEmail() {
        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.channel = 'chat';
        req.preferredRoast = 'Dark';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertEquals('New', r.buyerType, 'anonymous shoppers are treated as new until verified');
        System.assert(String.isNotBlank(r.primaryProductName), 'guest recommendation returns a real product');
        System.assert(String.isNotBlank(r.complementaryProductName), 'guest recommendation can still include a public add-on');
        System.assertEquals(Decimal.valueOf(20), r.primaryUnitPrice, 'primary unit price is grounded from standard pricebook');
        System.assertEquals(Decimal.valueOf(20), r.primaryLinePrice, 'primary line price reflects quantity');
        System.assertEquals(Decimal.valueOf(20), r.complementaryUnitPrice, 'add-on unit price is grounded from standard pricebook');
        System.assertEquals(Decimal.valueOf(20), r.complementaryLinePrice, 'add-on line price reflects quantity');
    }

    @isTest
    static void testDataCloudSpendFieldsDriveVipDiscountWhenCrmOrdersAreAbsent() {
        Id personRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(RecordTypeId = personRt, FirstName = 'CI', LastName = 'Spend',
            PersonEmail = 'ci.spend@example.com', Data_Cloud_Order_Count__c = 5,
            Data_Cloud_Lifetime_Value__c = 410, Data_Cloud_Favorite_Category__c = 'Single-Origin',
            Data_Cloud_Churn_Risk__c = 'Low');
        insert a;

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'ci.spend@example.com';
        req.channel = 'post_purchase';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertEquals('VIP', r.buyerType, 'Data Cloud lifetime value should classify the buyer as VIP');
        System.assertEquals(5, r.orderCount, 'order count falls back to the augmented Data Cloud field');
        System.assertEquals(Decimal.valueOf(410), r.lifetimeValue, 'LTV falls back to the augmented Data Cloud field');
        System.assertEquals(10, r.discountPercent, 'VIP/post_purchase = 10% from the matrix');
        System.assertEquals(true, r.couponEligible, 'low-risk calculated insight profile remains coupon eligible');
    }

    @isTest
    static void testReturnedProductsAreExcludedFromRecommendation() {
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'reco@example.com' LIMIT 1];
        Product2 returnedBean = [SELECT Id FROM Product2 WHERE Name = 'Bean B Single' LIMIT 1];
        Product2 replacementBean = mkProd('Bean C Replacement', 'Single-Origin');
        replacementBean.Stock_On_Hand__c = 90;
        insert replacementBean;

        ReturnOrder ro = new ReturnOrder(AccountId = a.Id, Return_Reason__c = 'Quality');
        insert ro;
        insert new ReturnOrderLineItem(ReturnOrderId = ro.Id, Product2Id = returnedBean.Id, QuantityReturned = 1);

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'chat';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assert(r.excludedIdsCsv.contains(String.valueOf(returnedBean.Id)), 'returned product appears in the exclude set');
        System.assertNotEquals(returnedBean.Id, r.primaryProductId, 'returned product must not be re-recommended');
    }

    @isTest
    static void testReturnRiskBlocksNormalSalesCouponInStrategy() {
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'reco@example.com' LIMIT 1];
        update new Account(Id = a.Id, Data_Cloud_Churn_Risk__c = 'High',
            Data_Cloud_Return_Count__c = 1, Has_Returned_Order__c = true, Return_Count__c = 1,
            Data_Cloud_Next_Best_Action__c = 'Resolve the service or return issue before making a new sales offer.');

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'post_purchase';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertEquals(false, r.couponEligible, 'return/service recovery risk blocks normal sales coupons');
        System.assertEquals(true, r.serviceRecoveryRequired, 'strategy exposes the recovery requirement to agents');
        System.assertEquals(0, r.discountPercent, 'blocked strategy must not return a usable discount');
        System.assert(r.discountRationale.contains('Service recovery guardrail'), r.discountRationale);
    }

    @isTest
    static void testBrowsedProductBeatsGenericAffinity() {
        // the shopper dwelled on Bean B (not bought, in stock) — the engine must offer exactly that
        Account a1 = [SELECT Id FROM Account WHERE PersonEmail = 'reco@example.com' LIMIT 1];
        Product2 beanB = [SELECT Id, Woo_Product_Id__c FROM Product2 WHERE Name = 'Bean B Single' LIMIT 1];
        insert new List<Web_Event__c>{
            new Web_Event__c(Account__c = a1.Id, Device_Id__c = 'RT', Event_Type__c = 'catalog',
                Product_Id__c = beanB.Woo_Product_Id__c, Product_Name__c = 'Bean B Single',
                Occurred_At__c = System.now().addDays(-1)),
            new Web_Event__c(Account__c = a1.Id, Device_Id__c = 'RT', Event_Type__c = 'pageEngagement',
                Product_Id__c = beanB.Woo_Product_Id__c, Product_Name__c = 'Bean B Single',
                Time_On_Page__c = 95, Occurred_At__c = System.now().addDays(-1))
        };

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'chat';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertEquals(beanB.Id, r.primaryProductId, 'dwelled-on product wins the primary slot');
        System.assert(String.isNotBlank(r.webSignal), 'web signal surfaced for the agent');
        System.assert(r.webSignal.contains('Bean B Single'), r.webSignal);
    }

    @isTest
    static void testDataCloudSdkBrowsingBeatsGenericAffinityWhenLegacyWebEventsAreGone() {
        Account a1 = [SELECT Id FROM Account WHERE PersonEmail = 'reco@example.com' LIMIT 1];
        update new Account(Id = a1.Id, Data_Cloud_Unified_Individual_Id__c = 'uid-reco-sdk');
        Product2 sdkBrowsed = mkProd('Bean D SDK Browse', 'Single-Origin');
        sdkBrowsed.Stock_On_Hand__c = 95;
        insert sdkBrowsed;

        RecommendationStrategyService.testDataCloudWebRows = new List<List<Object>>{
            new List<Object>{ sdkBrowsed.Woo_Product_Id__c, null, 125, String.valueOf(Date.today()) }
        };

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'chat';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertEquals(sdkBrowsed.Id, r.primaryProductId, 'SDK/Data Cloud browsed product wins even with no legacy Web_Event__c rows');
        System.assert(String.isNotBlank(r.webSignal), 'SDK web signal surfaced for the agent');
        System.assert(r.webSignal.contains('Bean D SDK Browse'), r.webSignal);
        System.assert(r.webSignal.contains('Data Cloud SDK'), r.webSignal);
    }

    @isTest
    static void testBrowsedButPurchasedProductIsNotReoffered() {
        // browsing your OWN past purchase must not bring it back — exclusion still wins
        Account a1 = [SELECT Id FROM Account WHERE PersonEmail = 'reco@example.com' LIMIT 1];
        Product2 beanA = [SELECT Id, Woo_Product_Id__c FROM Product2 WHERE Name = 'Bean A Single' LIMIT 1];
        insert new Web_Event__c(Account__c = a1.Id, Device_Id__c = 'RT', Event_Type__c = 'pageEngagement',
            Product_Id__c = beanA.Woo_Product_Id__c, Product_Name__c = 'Bean A Single',
            Time_On_Page__c = 120, Occurred_At__c = System.now());

        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.email = 'reco@example.com';
        req.channel = 'chat';

        Test.startTest();
        RecommendationStrategyService.Result r =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, r.success, r.summary);
        System.assertNotEquals(beanA.Id, r.primaryProductId, 'already-purchased product stays excluded even if browsed');
    }

    @isTest
    static void testBeanBrewBrandScopesToEquipment() {
        Id stdPb = Test.getStandardPricebookId();
        Product2 machine = new Product2(Name = 'BB Pro Machine', IsActive = true,
            Brand__c = 'Bean & Brew', ProductCode = 'BB-EQ-TEST');
        Product2 acc = new Product2(Name = 'BB Descaler', IsActive = true,
            Brand__c = 'Bean & Brew', ProductCode = 'BB-ACC-TEST');
        insert new List<Product2>{ machine, acc };
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPb, Product2Id = machine.Id, UnitPrice = 2199, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb, Product2Id = acc.Id, UnitPrice = 16, IsActive = true)
        };
        RecommendationStrategyService.Request req = new RecommendationStrategyService.Request();
        req.channel = 'chat';
        req.brand = 'Bean & Brew';   // the SITE the chat is on

        Test.startTest();
        RecommendationStrategyService.Result res =
            RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ req })[0];
        Test.stopTest();

        // Bean & Brew site → equipment primary + accessory complementary; NEVER coffee
        System.assertEquals('BB Pro Machine', res.primaryProductName, 'B&B site must recommend equipment, not coffee');
        System.assertEquals('BB Descaler', res.complementaryProductName, 'complementary should be a B&B accessory');
    }
}
