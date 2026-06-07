@isTest
private class PostPurchaseAutoOfferTest {

    private class WooMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(201);
            r.setBody('{"id":999,"code":"auto"}');
            return r;
        }
    }

    @isTest
    static void testHeadlessEnqueueCreatesOffer() {
        Id paRt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account pa = new Account(FirstName='Auto', LastName='Buyer', PersonEmail='auto.buyer@example.com',
            Email_Consent__c=true, RecordTypeId=paRt);
        insert pa;
        Product2 bought = new Product2(Name='Auto Bought', Family='Single-Origin', IsActive=true,
            StockKeepingUnit='A-BOUGHT', Stock_On_Hand__c=50, Woo_Product_Id__c='2001');
        Product2 recd = new Product2(Name='Auto Recommend', Family='Single-Origin', IsActive=true,
            StockKeepingUnit='A-REC', Stock_On_Hand__c=80, Woo_Product_Id__c='2002');
        insert new List<Product2>{ bought, recd };
        Id pb = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id=pb, Product2Id=bought.Id, UnitPrice=19, IsActive=true);
        insert pbe;
        Order ord = new Order(AccountId=pa.Id, EffectiveDate=Date.today(), Status='Draft',
            Pricebook2Id=pb, Woo_Order_Id__c='A-1', Source__c='Ecommerce');
        insert ord;
        insert new OrderItem(OrderId=ord.Id, PricebookEntryId=pbe.Id, Product2Id=bought.Id, Quantity=2, UnitPrice=19);
        update new Order(Id=ord.Id, Status='Activated', Fulfillment_Status__c='Shipped', Woo_Status__c='completed');

        Test.setMock(HttpCalloutMock.class, new WooMock());
        Test.startTest();
        PostPurchaseAutoOffer.Request req = new PostPurchaseAutoOffer.Request();
        req.orderId = ord.Id;
        PostPurchaseAutoOffer.run(new List<PostPurchaseAutoOffer.Request>{ req });
        Test.stopTest(); // Queueable executes here

        List<Coupon__c> coupons = [SELECT Code__c, Recommended_Product__r.Name FROM Coupon__c WHERE Order__c=:ord.Id];
        System.assertEquals(1, coupons.size(), 'headless job created exactly one coupon');
        System.assertEquals('Auto Recommend', coupons[0].Recommended_Product__r.Name, 'recommends in-category, non-purchased product');
    }
}
