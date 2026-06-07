@isTest
private class PostPurchaseServiceTest {

    private class WooCouponMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(201);
            res.setBody('{"id":555,"code":"testcode","amount":"15.00"}');
            return res;
        }
    }

    @testSetup
    static void setup() {
        Id paRt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account pa = new Account(
            FirstName='Test', LastName='Buyer', PersonEmail='test.buyer@example.com',
            Email_Consent__c=true, RecordTypeId=paRt
        );
        insert pa;

        // Purchased product (Single-Origin) + a recommendation candidate in same category.
        Product2 bought = new Product2(Name='Bought Bean', Family='Single-Origin', IsActive=true,
            StockKeepingUnit='T-BOUGHT', Stock_On_Hand__c=50, Woo_Product_Id__c='1001');
        Product2 recProd = new Product2(Name='Recommend Bean', Family='Single-Origin', IsActive=true,
            StockKeepingUnit='T-REC', Stock_On_Hand__c=80, Woo_Product_Id__c='1002');
        insert new List<Product2>{ bought, recProd };

        Id pbId = Test.getStandardPricebookId();
        PricebookEntry pbeBought = new PricebookEntry(Pricebook2Id=pbId, Product2Id=bought.Id, UnitPrice=19, IsActive=true);
        insert pbeBought;

        Order ord = new Order(AccountId=pa.Id, EffectiveDate=Date.today(), Status='Draft',
            Pricebook2Id=pbId, Woo_Order_Id__c='T-9999');
        insert ord;

        OrderItem oi = new OrderItem(OrderId=ord.Id, PricebookEntryId=pbeBought.Id,
            Product2Id=bought.Id, Quantity=2, UnitPrice=19);
        insert oi;
        update new Order(Id=ord.Id, Status='Activated', Fulfillment_Status__c='Shipped', Woo_Status__c='completed');
    }

    @isTest
    static void testGenerateOffer() {
        Order ord = [SELECT Id FROM Order WHERE Woo_Order_Id__c='T-9999' LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new WooCouponMock());

        Test.startTest();
        PostPurchaseService.Request req = new PostPurchaseService.Request();
        req.orderId = ord.Id;
        List<PostPurchaseService.Result> results = PostPurchaseService.generateOffer(
            new List<PostPurchaseService.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'one result');
        PostPurchaseService.Result r = results[0];
        System.assertEquals(true, r.success, 'should succeed: ' + r.summary);
        System.assertEquals('Single-Origin', r.favoriteCategory, 'favorite category');
        System.assertEquals('Recommend Bean', r.recommendedProduct, 'recommends the non-purchased in-category product');
        System.assertEquals(15, r.discountPercent, 'order < 100 => 15%');
        System.assert(r.couponCode.startsWith('BREW'), 'code prefixed: ' + r.couponCode);

        Coupon__c c = [SELECT Code__c, Status__c, Woo_Coupon_Id__c, Discount_Percent__c,
                              Recommended_Product__r.Name, Account__r.PersonEmail
                       FROM Coupon__c WHERE Order__c=:ord.Id LIMIT 1];
        System.assertEquals(r.couponCode, c.Code__c, 'coupon code persisted');
        System.assertEquals('Issued', c.Status__c, 'issued');
        System.assertEquals('555', c.Woo_Coupon_Id__c, 'woo id captured from callout');
        System.assertEquals('Recommend Bean', c.Recommended_Product__r.Name, 'rec product linked');
    }

    @isTest
    static void testRecurrentBuyerGetsSmallerDiscount() {
        // Discount is now buyer-aware: a RECURRENT buyer (3+ purchases in last 12mo) gets a SMALLER
        // post-purchase discount (12%) than a one-time/Occasional buyer (15%). More loyal => less aggressive.
        Order ord = [SELECT Id, AccountId, Pricebook2Id FROM Order WHERE Woo_Order_Id__c='T-9999' LIMIT 1];
        // make this account RECURRENT: add 2 more recent orders (3 total in last 12mo)
        insert new List<Order>{
            new Order(AccountId=ord.AccountId, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=ord.Pricebook2Id),
            new Order(AccountId=ord.AccountId, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=ord.Pricebook2Id)
        };

        Test.setMock(HttpCalloutMock.class, new WooCouponMock());
        Test.startTest();
        PostPurchaseService.Result r = PostPurchaseService.buildOffer(ord.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'success');
        System.assertEquals(12, r.discountPercent, 'Recurrent buyer => 12% (smaller than Occasional 15%)');
    }

    @isTest
    static void testNoConsentSkipsEverything() {
        // Revoke consent on the buyer; the offer must abort up front with NO coupon, NO callout.
        Account pa = [SELECT Id FROM Account WHERE PersonEmail='test.buyer@example.com' LIMIT 1];
        update new Account(Id=pa.Id, Email_Consent__c=false);
        Order ord = [SELECT Id FROM Order WHERE Woo_Order_Id__c='T-9999' LIMIT 1];

        Test.startTest();
        PostPurchaseService.Result r = PostPurchaseService.buildOffer(ord.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'no consent -> not successful');
        System.assertEquals(null, r.couponCode, 'no coupon code generated');
        System.assert(r.summary.contains('consent'), 'summary explains consent: ' + r.summary);
        System.assertEquals(0, [SELECT count() FROM Coupon__c WHERE Order__c=:ord.Id], 'no coupon persisted');
    }

    @isTest
    static void testCancelledOrderSkipsOfferEvenWithConsent() {
        Order base = [SELECT AccountId, Pricebook2Id FROM Order WHERE Woo_Order_Id__c='T-9999' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry WHERE Pricebook2Id=:base.Pricebook2Id LIMIT 1];
        Order ord = new Order(AccountId=base.AccountId, EffectiveDate=Date.today(), Status='Draft',
            Pricebook2Id=base.Pricebook2Id, Woo_Order_Id__c='T-CANCEL');
        insert ord;
        insert new OrderItem(OrderId=ord.Id, PricebookEntryId=pbe.Id, Product2Id=pbe.Product2Id, Quantity=1, UnitPrice=pbe.UnitPrice);
        update new Order(Id=ord.Id, Status='Activated', Fulfillment_Status__c='Processing', Woo_Status__c='processing');
        update new Order(Id=ord.Id, Fulfillment_Status__c='Cancelled', Woo_Status__c='cancelled');

        Test.startTest();
        PostPurchaseService.Result r = PostPurchaseService.buildOffer(ord.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'cancelled order should not receive a buy-again offer');
        System.assertEquals(null, r.couponCode, 'no coupon code generated');
        System.assert(r.summary.contains('not eligible'), 'summary explains eligibility: ' + r.summary);
        System.assertEquals(0, [SELECT count() FROM Coupon__c WHERE Order__c=:ord.Id], 'no coupon persisted');
    }

    @isTest
    static void testReturnRiskSkipsNormalPostPurchaseCoupon() {
        Account pa = [SELECT Id FROM Account WHERE PersonEmail='test.buyer@example.com' LIMIT 1];
        update new Account(Id=pa.Id, Data_Cloud_Churn_Risk__c='High',
            Data_Cloud_Return_Count__c=1, Has_Returned_Order__c=true, Return_Count__c=1,
            Data_Cloud_Next_Best_Action__c='Resolve the service or return issue before making a new sales offer.');
        Order ord = [SELECT Id FROM Order WHERE Woo_Order_Id__c='T-9999' LIMIT 1];

        Test.startTest();
        PostPurchaseService.Result r = PostPurchaseService.buildOffer(ord.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'active return/service recovery risk should skip normal growth offers');
        System.assertEquals(null, r.couponCode, 'no coupon code generated');
        System.assert(r.summary.contains('return/service recovery risk'), 'summary explains the risk gate: ' + r.summary);
        System.assertEquals(0, [SELECT count() FROM Coupon__c WHERE Order__c=:ord.Id], 'no coupon persisted');
    }
}
