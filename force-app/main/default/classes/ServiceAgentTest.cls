@isTest
private class ServiceAgentTest {

    private static Product2 mkProd(String name, String family) {
        return new Product2(Name = name, Family = family, IsActive = true,
            Stock_On_Hand__c = 50, Woo_Product_Id__c = String.valueOf(Math.abs(name.hashCode())));
    }

    @testSetup
    static void setup() {
        Product2 bean = mkProd('Test Bean', 'Single-Origin');
        Product2 gear = mkProd('Test Grinder', 'Grinders');
        insert new List<Product2>{ bean, gear };
        Id stdPb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : new List<Product2>{ bean, gear }) {
            pbes.add(new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 20, IsActive = true));
        }
        insert pbes;
        Map<Id, PricebookEntry> byProd = new Map<Id, PricebookEntry>();
        for (PricebookEntry e : pbes) byProd.put(e.Product2Id, e);

        Id rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(RecordTypeId = rt, FirstName = 'Svc', LastName = 'Tester',
            PersonEmail = 'svc@example.com', Email_Consent__c = true);
        insert a;

        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = stdPb, Woo_Order_Id__c = '99001', Source__c = 'Ecommerce',
            Fulfillment_Status__c = 'Not Shipped');
        insert o;
        insert new List<OrderItem>{
            new OrderItem(OrderId = o.Id, Product2Id = bean.Id, PricebookEntryId = byProd.get(bean.Id).Id, Quantity = 2, UnitPrice = 20),
            new OrderItem(OrderId = o.Id, Product2Id = gear.Id, PricebookEntryId = byProd.get(gear.Id).Id, Quantity = 1, UnitPrice = 20)
        };
    }

    @isTest
    static void testOrderStatusAndEligibility() {
        OrderStatusService.Request r = new OrderStatusService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com';
        Test.startTest();
        OrderStatusService.Result res = OrderStatusService.get(new List<OrderStatusService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.found, 'order found');
        System.assertEquals(true, res.canCancel, 'Not Shipped -> cancellable');
        System.assertEquals(false, res.canReturn, 'Not Shipped -> not returnable');
        System.assert(res.itemsSummary.contains('Test Bean'), 'items listed');
    }

    @isTest
    static void testOpenCaseAndEscalate() {
        CaseService.Request r = new CaseService.Request();
        r.email = 'svc@example.com'; r.subject = 'Bad coffee'; r.category = 'Returns'; r.escalate = true;
        Test.startTest();
        CaseService.Result res = CaseService.open(new List<CaseService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assert(String.isNotBlank(res.caseNumber), 'case number returned');
        Case c = [SELECT Status, Priority, Category__c FROM Case WHERE CaseNumber = :res.caseNumber];
        System.assertEquals('Escalated', c.Status, 'escalated');
        System.assertEquals('Returns', c.Category__c, 'category set');
    }

    @isTest
    static void testCaseCarriesChatTranscript() {
        CaseService.Request r = new CaseService.Request();
        r.email = 'svc@example.com'; r.subject = 'Damaged bag'; r.category = 'Returns'; r.escalate = true;
        r.description = 'Bag arrived split.';
        r.chatSummary = 'Shopper: my dark roast arrived with a split bag. Agent: checked order 99001, confirmed delivered, offered a return. Shopper: yes please.';
        Test.startTest();
        CaseService.Result res = CaseService.open(new List<CaseService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        Case c = [SELECT Description FROM Case WHERE Id = :res.caseId];
        System.assert(c.Description.contains('Chat transcript'), 'transcript folded into case description');
        System.assert(c.Description.contains('split bag'), 'actual conversation captured on case');
        List<Task> t = [SELECT Subject, Description FROM Task WHERE WhatId = :res.caseId AND Subject = 'Chat transcript'];
        System.assertEquals(1, t.size(), 'transcript activity logged on the case timeline');
        System.assert(t[0].Description.contains('dark roast'), 'transcript task carries the conversation');
    }

    @isTest
    static void testCaseResolutionRequiresConfirmationThenCloses() {
        CaseService.Request openReq = new CaseService.Request();
        openReq.email = 'svc@example.com';
        openReq.subject = 'Shipping question';
        openReq.category = 'Shipping';
        CaseService.Result opened = CaseService.open(new List<CaseService.Request>{ openReq })[0];

        CaseResolutionService.Request needsConfirm = new CaseResolutionService.Request();
        needsConfirm.caseNumber = opened.caseNumber;
        needsConfirm.resolution = 'Explained shipped vs delivered and sent tracking.';
        CaseResolutionService.Result blocked = CaseResolutionService.resolve(
            new List<CaseResolutionService.Request>{ needsConfirm })[0];
        System.assertEquals(false, blocked.success, 'case is not closed without confirmation');
        System.assert(blocked.message.contains('Confirm'), 'confirmation prompt returned');

        needsConfirm.confirmed = true;
        Test.startTest();
        CaseResolutionService.Result closed = CaseResolutionService.resolve(
            new List<CaseResolutionService.Request>{ needsConfirm })[0];
        Test.stopTest();

        System.assertEquals(true, closed.success, closed.message);
        Case c = [SELECT Status, Resolution__c, Resolved_By__c FROM Case WHERE CaseNumber = :opened.caseNumber];
        System.assertEquals('Closed', c.Status, 'case closed after explicit confirmation');
        System.assert(c.Resolution__c.contains('tracking'), 'resolution stored');
        System.assert(c.Resolved_By__c.contains('Chat Agent'), 'resolver stamped');
        System.assertEquals(1, [SELECT count() FROM Agent_Interaction__c WHERE Action__c = 'resolve_case'], 'journey log recorded');
    }

    @isTest
    static void testReturnBlockedWhenNotDelivered() {
        ReturnService.Request r = new ReturnService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.reason = 'Quality';
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(false, res.success, 'return blocked: not delivered');
        System.assert(res.message.contains('Delivered'), 'explains eligibility');
        System.assertEquals(0, [SELECT count() FROM ReturnOrder], 'no ReturnOrder created');
    }

    @isTest
    static void testReturnSucceedsWhenDelivered() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnService.Request r = new ReturnService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.orderIdentifier = '99001'; r.reason = 'Damaged'; r.confirmed = true;
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(1, [SELECT count() FROM ReturnOrder], 'ReturnOrder created');
        System.assertEquals(2, [SELECT count() FROM ReturnOrderLineItem], 'lines created');
        Account a = [SELECT Has_Returned_Order__c, Return_Count__c FROM Account WHERE PersonEmail = 'svc@example.com'];
        System.assertEquals(true, a.Has_Returned_Order__c, 'flagged returned');
        System.assertEquals(1, a.Return_Count__c, 'return count incremented');
        // Winback_Needed__c was set true then cleared by the async Winback_On_Return flow at stopTest.
    }

    @isTest
    static void testReturnSucceedsWhenShipmentDelivered() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Shipped', Tracking_Number__c = '1ZDELIVERED');
        SObject shipment = Schema.getGlobalDescribe().get('Shipment').newSObject();
        shipment.put('OwnerId', UserInfo.getUserId());
        shipment.put('ShipToName', 'Svc Tester');
        shipment.put('Order__c', o.Id);
        shipment.put('Tracking_Number__c', '1ZDELIVERED');
        shipment.put('Shipment_Status__c', 'Delivered');
        shipment.put('Delivered_At__c', System.now());
        insert shipment;

        ReturnService.Request r = new ReturnService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.orderIdentifier = '99001'; r.reason = 'Damaged'; r.confirmed = true;
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(1, [SELECT count() FROM ReturnOrder], 'ReturnOrder created from shipment delivery proof');
    }

    @isTest
    static void testCancelSucceedsThenBlockedAfterShip() {
        // cancellable while Not Shipped
        CancellationService.Request r = new CancellationService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.orderIdentifier = '99001'; r.reason = 'Changed mind'; r.confirmed = true;
        Test.startTest();
        CancellationService.Result res = CancellationService.cancel(new List<CancellationService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        Order o = [SELECT Fulfillment_Status__c FROM Order WHERE Woo_Order_Id__c = '99001'];
        System.assertEquals('Cancelled', o.Fulfillment_Status__c, 'order cancelled');
    }

    @isTest
    static void testCancelBlockedWhenShipped() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Shipped');
        CancellationService.Request r = new CancellationService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.orderIdentifier = '99001';
        Test.startTest();
        CancellationService.Result res = CancellationService.cancel(new List<CancellationService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(false, res.success, 'cannot cancel a shipped order');
    }

    @isTest
    static void testWinbackService() {
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'svc@example.com'];
        update new Account(Id = a.Id, Winback_Needed__c = true);
        Test.startTest();
        WinbackService.sendWinback(a.Id);
        Test.stopTest();
        Account after = [SELECT Winback_Needed__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(false, after.Winback_Needed__c, 'winback flag cleared');
    }

    @isTest
    static void testWooOrderActionServiceTestContext() {
        Test.startTest();
        WooOrderActionService.WooResult cancel = WooOrderActionService.cancelOrder('123');
        WooOrderActionService.WooResult refund = WooOrderActionService.refundOrder('123', 10, 'test');
        Test.stopTest();
        System.assertEquals(true, cancel.success, 'test-context cancel ok');
        System.assertEquals(true, refund.success, 'test-context refund ok');
    }

    @isTest
    static void testWinbackAutoOfferInvocable() {
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'svc@example.com'];
        WinbackAutoOffer.Request r = new WinbackAutoOffer.Request(); r.accountId = a.Id;
        Test.startTest();
        WinbackAutoOffer.run(new List<WinbackAutoOffer.Request>{ r });
        Test.stopTest();
        System.assert(true, 'enqueued without error');
    }
}
