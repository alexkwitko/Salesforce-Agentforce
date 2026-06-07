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
}
