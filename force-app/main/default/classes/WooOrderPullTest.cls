@isTest
private class WooOrderPullTest {
    private class OrdersMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse(); r.setStatusCode(200);
            r.setBody('[{"id":88888,"status":"processing","customer_id":0,"billing":{"first_name":"Pull","last_name":"Test","email":"pull.test@example.com","phone":"123"},"line_items":[{"product_id":5001,"quantity":1,"price":"15"}],"meta_data":[{"key":"_wc_other/kwitko/marketing_consent","value":"1"}],"coupon_lines":[]}]');
            return r;
        }
    }
    @TestSetup static void setup() {
        Product2 p = new Product2(Name='Pull Coffee', Family='Single-Origin', IsActive=true,
            StockKeepingUnit='P-1', Stock_On_Hand__c=10, Woo_Product_Id__c='5001');
        insert p;
        insert new PricebookEntry(Pricebook2Id=Test.getStandardPricebookId(), Product2Id=p.Id, UnitPrice=15, IsActive=true);
    }
    @isTest static void testPullIngestsAndSyncsConsent() {
        Test.setMock(HttpCalloutMock.class, new OrdersMock());
        Test.startTest();
        WooOrderPull.pull();
        Test.stopTest();
        System.assertEquals(1, [SELECT count() FROM Order WHERE Woo_Order_Id__c='88888'], 'order ingested via pull');
        System.assertEquals(true,
            [SELECT Email_Consent__c FROM Account WHERE PersonEmail='pull.test@example.com' LIMIT 1].Email_Consent__c,
            'checkout consent synced via pull');
    }

    @isTest static void testWooCompletedWithTrackingCreatesFulfillmentAndShipmentButNotDelivered() {
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
            '{"id":88999,"status":"completed","date_paid":"2026-06-06T12:00:00Z","customer_id":0,'
            + '"billing":{"first_name":"Ship","last_name":"Test","email":"ship.test@example.com","phone":"123"},'
            + '"shipping":{"address_1":"1 Test St","city":"Austin","state":"TX","postcode":"78701","country":"US"},'
            + '"line_items":[{"product_id":5001,"quantity":1,"price":"15"}],'
            + '"meta_data":[{"key":"_wc_shipment_tracking_items","value":[{"tracking_number":"1ZTESTSHIP","tracking_provider":"UPS","custom_tracking_link":"https://example.com/track/1ZTESTSHIP"}]}],'
            + '"coupon_lines":[]}'
        );

        Test.startTest();
        Id orderId = WooOrderService.ingestOrder(payload);
        Test.stopTest();

        Order o = [SELECT Id, Fulfillment_Status__c, Tracking_Number__c FROM Order WHERE Id = :orderId];
        System.assertEquals('Shipped', o.Fulfillment_Status__c, 'Woo completed means shipped/fulfilled, not delivered');
        System.assertEquals('1ZTESTSHIP', o.Tracking_Number__c, 'tracking copied to Order');
        System.assertEquals(1, [SELECT count() FROM FulfillmentOrder WHERE OrderId = :orderId], 'fulfillment order created');

        Shipment sh = [
            SELECT Order__c, Fulfillment_Order__c, Shipment_Status__c, Tracking_Number__c, Carrier__c, Tracking_Url__c
            FROM Shipment
            WHERE Order__c = :orderId
            LIMIT 1
        ];
        System.assertEquals(orderId, sh.Order__c, 'shipment linked to order');
        System.assertNotEquals(null, sh.Fulfillment_Order__c, 'shipment linked to fulfillment order');
        System.assertEquals('Shipped', sh.Shipment_Status__c, 'shipment is shipped, not delivered');
        System.assertEquals('1ZTESTSHIP', sh.Tracking_Number__c, 'shipment carries tracking');

        FulfillmentTruthService.Snapshot truth = FulfillmentTruthService.forOrder(o);
        System.assertEquals('Shipped', truth.effectiveStatus, 'truth layer must not call this delivered');
        System.assertEquals('Shipment', truth.statusSource, 'shipment should be the answer source once tracking exists');
        System.assertEquals(false, truth.hasDeliveryProof, 'no delivery proof from Woo completed alone');
    }
}
