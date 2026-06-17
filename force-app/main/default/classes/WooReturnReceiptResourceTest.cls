@isTest
private class WooReturnReceiptResourceTest {
    private static String lastRefundBody;
    private static String lastRefundEndpoint;

    private class WooActionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/refunds')) {
                lastRefundEndpoint = req.getEndpoint();
                lastRefundBody = req.getBody();
                resp.setStatusCode(201);
                resp.setBody('{"id":88011}');
            } else if (req.getEndpoint().contains('/notes')) {
                resp.setStatusCode(201);
                resp.setBody('{"id":88012}');
            } else {
                resp.setStatusCode(200);
                resp.setBody('{"ok":true}');
            }
            return resp;
        }
    }

    @testSetup
    static void setup() {
        insert new Woo_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Webhook_Secret__c = 'topsecret');

        Product2 bean = new Product2(Name = 'Return Test Bean', Family = 'Single-Origin',
            IsActive = true, Woo_Product_Id__c = '9001');
        insert bean;
        Id stdPb = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = stdPb, Product2Id = bean.Id,
            UnitPrice = 20, IsActive = true);
        insert pbe;

        Id rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(RecordTypeId = rt, FirstName = 'Return', LastName = 'Receiver',
            PersonEmail = 'return.receiver@example.com', Email_Consent__c = true);
        insert a;

        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = stdPb, Woo_Order_Id__c = '99111', Source__c = 'Ecommerce',
            Fulfillment_Status__c = 'Delivered', Payment_Status__c = 'Paid', Woo_Order_Total__c = 40);
        insert o;
        insert new OrderItem(OrderId = o.Id, Product2Id = bean.Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 20, Woo_Line_Item_Id__c = '501');

        ReturnOrder ro = new ReturnOrder(AccountId = a.Id, Order__c = o.Id, Return_Reason__c = 'Quality',
            Return_Label_Url__c = 'https://example.com/label', Return_Tracking__c = 'KWRET99111',
            Refund_Amount__c = 20, Status = 'Submitted');
        insert ro;
        insert new ReturnOrderLineItem(ReturnOrderId = ro.Id, Product2Id = bean.Id,
            QuantityReturned = 1, QuantityExpected = 1, UnitPrice = 20,
            ReasonForReturn = 'Not Satisfied', RepaymentMethod = 'Refund', Woo_Line_Item_Id__c = '501');
        insert new Case(AccountId = a.Id, ContactId = a.PersonContactId, Order__c = o.Id,
            Woo_Order_Id__c = '99111', Origin = 'Chat', Status = 'New', Priority = 'Medium',
            Category__c = 'Returns', Subject = 'Return started - order #99111',
            Description = 'Return is pending receipt.');
    }

    @isTest
    static void hmacPostReceivesReturnAndClosesCase() {
        String json = JSON.serialize(new Map<String, Object>{
            'order_id' => '99111',
            'tracking' => 'KWRET99111',
            'received_note' => 'Woo admin received one bag.',
            'source' => 'woocommerce_admin_order_action',
            'received_by' => 'warehouse@example.com'
        });
        Blob body = Blob.valueOf(json);
        String sig = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', body, Blob.valueOf('topsecret')));
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/woo/return-receipt/';
        req.httpMethod = 'POST';
        req.requestBody = body;
        req.headers.put('X-Kwitko-Signature', sig);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.setMock(HttpCalloutMock.class, new WooActionMock());
        WooOrderActionService.allowHttpInTests = true;
        lastRefundBody = null;
        lastRefundEndpoint = null;
        Test.startTest();
        WooReturnReceiptResource.handlePost();
        Test.stopTest();
        WooOrderActionService.allowHttpInTests = false;

        System.assertEquals(200, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        ReturnOrder ro = [SELECT Status, Woo_Refund_Id__c FROM ReturnOrder WHERE Return_Tracking__c = 'KWRET99111' LIMIT 1];
        System.assertEquals('Closed', ro.Status, 'return closed after Woo receipt callback');
        System.assertEquals('88011', ro.Woo_Refund_Id__c, 'Woo refund id stored');
        Order o = [SELECT Fulfillment_Status__c, Payment_Status__c, Woo_Refund_Id__c FROM Order WHERE Woo_Order_Id__c = '99111'];
        System.assertEquals('Refunded', o.Fulfillment_Status__c);
        System.assertEquals('Refunded', o.Payment_Status__c);
        System.assertEquals('88011', o.Woo_Refund_Id__c);
        Case c = [SELECT Status, Resolution__c, Description FROM Case WHERE Woo_Order_Id__c = '99111' LIMIT 1];
        System.assertEquals('Closed', c.Status, 'returns case closed');
        System.assert(c.Resolution__c.contains('WooCommerce refund 88011'), c.Resolution__c);
        System.assert(c.Description.contains('Woo admin received one bag'), c.Description);
        System.assert(lastRefundEndpoint != null && lastRefundEndpoint.endsWith('/orders/99111/refunds'),
            'Woo refund endpoint targets the source Woo order');
        System.assert(lastRefundBody.contains('"amount":"20.00"'), lastRefundBody);
        System.assert(lastRefundBody.contains('"line_items"'), lastRefundBody);
        System.assert(lastRefundBody.contains('"id":501'), lastRefundBody);
        System.assert(lastRefundBody.contains('"refund_total":"20.00"'), lastRefundBody);
    }

    @isTest
    static void hmacRejectsBadSignature() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/woo/return-receipt/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"order_id":"99111"}');
        req.headers.put('X-Kwitko-Signature', 'wrong');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        WooReturnReceiptResource.handlePost();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode);
    }
}
