@isTest
private class CarrierShippingServiceTest {

    private class EasyPostMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req){
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200); r.setHeader('Content-Type','application/json');
            if (req.getEndpoint().endsWith('/buy')) {
                r.setBody('{"id":"shp_1","tracking_code":"EZ1234567890",' +
                    '"selected_rate":{"carrier":"USPS","rate":"7.50"},' +
                    '"tracker":{"public_url":"https://track.easypost.com/EZ1234567890"},' +
                    '"postage_label":{"label_url":"https://easypost.com/label.pdf"}}');
            } else {
                r.setBody('{"id":"shp_1","rates":[' +
                    '{"id":"rate_1","rate":"7.50","carrier":"USPS"},' +
                    '{"id":"rate_2","rate":"12.00","carrier":"FedEx"}]}');
            }
            return r;
        }
    }

    private static Order makeOrder(){
        Account a = new Account(Name='Ship Test'); insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft',
            Pricebook2Id=Test.getStandardPricebookId(),
            ShippingStreet='1 Main St', ShippingCity='San Francisco', ShippingPostalCode='94103');
        insert o;
        return o;
    }

    @isTest static void liveCarrierBuysLabel(){
        KwitkoSecrets.overrides.put('EasyPost_API_Key','EZTK_test_key');
        Order o = makeOrder();
        Test.setMock(HttpCalloutMock.class, new EasyPostMock());
        Test.startTest();
        CarrierShippingService.Result res = CarrierShippingService.shipOrder(o.Id);
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(false, res.usedMock, 'should use the live carrier when a key is set');
        System.assertEquals('EZ1234567890', res.trackingNumber);
        System.assertEquals('USPS', res.carrier);
        Order chk = [SELECT Fulfillment_Status__c, Tracking_Number__c, Carrier__c FROM Order WHERE Id=:o.Id];
        System.assertEquals('Shipped', chk.Fulfillment_Status__c);
        System.assertEquals('EZ1234567890', chk.Tracking_Number__c);
        System.assertEquals('USPS', chk.Carrier__c);
    }

    @isTest static void mockFallbackWhenNoKey(){
        Order o = makeOrder();
        Test.startTest();
        CarrierShippingService.Result res = CarrierShippingService.shipOrder(o.Id);
        Test.stopTest();
        System.assertEquals(true, res.success);
        System.assertEquals(true, res.usedMock, 'no key configured -> mock label');
        System.assertNotEquals(null, res.trackingNumber);
        Order chk = [SELECT Fulfillment_Status__c FROM Order WHERE Id=:o.Id];
        System.assertEquals('Shipped', chk.Fulfillment_Status__c);
    }

    @isTest static void invocableEntrypoint(){
        Order o = makeOrder();
        CarrierShippingService.Request req = new CarrierShippingService.Request();
        req.orderId = o.Id;
        Test.startTest();
        List<CarrierShippingService.Result> res = CarrierShippingService.ship(new List<CarrierShippingService.Request>{req});
        Test.stopTest();
        System.assertEquals(1, res.size());
        System.assertEquals(true, res[0].success);
    }
}
