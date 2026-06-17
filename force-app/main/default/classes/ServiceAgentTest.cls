@isTest
private class ServiceAgentTest {
    private static String lastRefundBody;
    private static String lastRefundEndpoint;
    private static String lastLabelEmailBody;
    private static String lastLabelEmailEndpoint;
    private static String lastVerificationEmailBody;
    private static String lastVerificationEmailEndpoint;

    private static Product2 mkProd(String name, String family) {
        return new Product2(Name = name, Family = family, IsActive = true,
            Stock_On_Hand__c = 50, Woo_Product_Id__c = String.valueOf(Math.abs(name.hashCode())));
    }

    private class WooActionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(200);
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/refunds')) {
                lastRefundEndpoint = req.getEndpoint();
                lastRefundBody = req.getBody();
                resp.setStatusCode(201);
                resp.setBody('{"id":77701}');
            } else if (req.getEndpoint().contains('/wp-json/kwitko/v1/me')) {
                resp.setStatusCode(200);
                resp.setBody('{"logged_in":false,"bridge_version":"20260615.7"}');
            } else if (req.getEndpoint().contains('/return-label-email')) {
                lastLabelEmailEndpoint = req.getEndpoint();
                lastLabelEmailBody = req.getBody();
                resp.setStatusCode(200);
                resp.setBody('{"ok":true,"message":"sent"}');
            } else if (req.getEndpoint().contains('/verification-code-email')) {
                lastVerificationEmailEndpoint = req.getEndpoint();
                lastVerificationEmailBody = req.getBody();
                resp.setStatusCode(200);
                resp.setBody('{"ok":true,"message":"sent"}');
            } else if (req.getEndpoint().contains('/notes')) {
                resp.setStatusCode(201);
                resp.setBody('{"id":77802}');
            } else {
                resp.setBody('{"id":123,"status":"ok"}');
            }
            return resp;
        }
    }

    private class WooCancelFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/refunds')) {
                lastRefundEndpoint = req.getEndpoint();
                lastRefundBody = req.getBody();
                resp.setStatusCode(201);
                resp.setBody('{"id":99999}');
            } else {
                resp.setStatusCode(500);
                resp.setBody('{"message":"store refused cancellation"}');
            }
            return resp;
        }
    }

    private class WooLabelEmailFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/return-label-email')) {
                lastLabelEmailEndpoint = req.getEndpoint();
                lastLabelEmailBody = req.getBody();
                resp.setStatusCode(404);
                resp.setBody('{"code":"rest_no_route","message":"No route"}');
            } else if (req.getEndpoint().contains('/wp-json/kwitko/v1/me')) {
                resp.setStatusCode(200);
                resp.setBody('{"logged_in":false,"bridge_version":"20260615.7"}');
            } else if (req.getEndpoint().contains('/notes')) {
                resp.setStatusCode(201);
                resp.setBody('{"id":77802}');
            } else {
                resp.setStatusCode(200);
                resp.setBody('{"ok":true}');
            }
            return resp;
        }
    }

    private class WooRefundFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/refunds')) {
                resp.setStatusCode(500);
                resp.setBody('{"message":"gateway refund failed"}');
            } else {
                resp.setStatusCode(201);
                resp.setBody('{"id":77802}');
            }
            return resp;
        }
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
            new OrderItem(OrderId = o.Id, Product2Id = bean.Id, PricebookEntryId = byProd.get(bean.Id).Id,
                Quantity = 2, UnitPrice = 20, Woo_Line_Item_Id__c = '101'),
            new OrderItem(OrderId = o.Id, Product2Id = gear.Id, PricebookEntryId = byProd.get(gear.Id).Id,
                Quantity = 1, UnitPrice = 20, Woo_Line_Item_Id__c = '102')
        };
    }

    @isTest
    static void testOrderStatusAndEligibility() {
        OrderStatusService.Request r = new OrderStatusService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com';
        r.orderIdentifier = '#99001';
        r.chatSummary = 'Shopper asked for last order status. Agent verified svc@example.com with code 826724 and checked order #99001.';
        Test.startTest();
        OrderStatusService.Result res = OrderStatusService.get(new List<OrderStatusService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.found, 'order found');
        System.assertEquals('#99001', res.orderNumber, 'shopper sees Woo order number, not Salesforce auto-number');
        System.assertEquals('99001', res.wooOrderId, 'Woo order id still returned separately');
        System.assertEquals(true, res.canCancel, 'Not Shipped -> cancellable');
        System.assertEquals(false, res.canReturn, 'Not Shipped -> not returnable');
        System.assert(res.itemsSummary.contains('Test Bean'), 'items listed');
        System.assert(res.summary.contains('Order #99001'), res.summary);
        Order sourceOrder = [SELECT OrderNumber FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        System.assert(!res.summary.contains(sourceOrder.OrderNumber),
            'summary must not expose the Salesforce internal order auto-number');
        Case auditCase = [SELECT Status, Subject, Resolution__c, Description, CaseNumber, Service_Interaction_Id__c
                          FROM Case WHERE Subject = 'Chat service: Order status answered' LIMIT 1];
        System.assertEquals('Closed', auditCase.Status, 'solved service answer creates a closed case');
        System.assert(auditCase.Resolution__c.contains('Order #99001'), 'resolution stores answer given');
        System.assert(auditCase.Description.contains('Shopper asked for last order status'), 'chat transcript stored');
        System.assert(auditCase.Description.contains('code [redacted]'), auditCase.Description);
        System.assert(!auditCase.Description.contains('826724'), auditCase.Description);
        Agent_Interaction__c interaction = [
            SELECT Id, Result__c
            FROM Agent_Interaction__c
            WHERE Action__c = 'get_order_status'
            LIMIT 1
        ];
        System.assertEquals(String.valueOf(interaction.Id), auditCase.Service_Interaction_Id__c,
            'closed service case is linked to the exact journey interaction');
        System.assert(interaction.Result__c.contains('Case ' + auditCase.CaseNumber + ' created.'),
            'journey log records the case number returned to the shopper');
        List<Task> auditTasks = [
            SELECT Description
            FROM Task
            WHERE WhatId = :auditCase.Id AND Subject = 'Chat transcript'
        ];
        System.assertEquals(1, auditTasks.size(),
            'transcript also appears on case timeline');
        System.assert(auditTasks[0].Description.contains('Order #99001'), auditTasks[0].Description);
        System.assert(auditTasks[0].Description.contains('Shopper asked for last order status'), auditTasks[0].Description);
        System.assert(auditTasks[0].Description.contains('code [redacted]'), auditTasks[0].Description);
        System.assert(!auditTasks[0].Description.contains('826724'), auditTasks[0].Description);
    }

    @isTest
    static void testOrderStatusDoesNotExposeSalesforceOrderNumberWhenWooIdMissing() {
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'svc@example.com' LIMIT 1];
        Order noWoo = new Order(
            AccountId = a.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            Source__c = 'Ecommerce',
            Fulfillment_Status__c = 'Processing'
        );
        insert noWoo;
        noWoo = [SELECT Id, OrderNumber FROM Order WHERE Id = :noWoo.Id LIMIT 1];

        OrderStatusService.Request r = new OrderStatusService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.chatSummary = 'Shopper asked for the latest order but the Woo order id was missing on the CRM record.';

        Test.startTest();
        OrderStatusService.Result res = OrderStatusService.get(new List<OrderStatusService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.found, 'latest order is still found');
        System.assertEquals('this order', res.orderNumber, 'missing Woo id uses neutral wording');
        System.assertEquals(null, res.wooOrderId, 'Woo id is honestly blank');
        System.assert(!res.summary.contains(noWoo.OrderNumber),
            'summary must not fall back to the Salesforce internal order auto-number');
        Case auditCase = [SELECT Resolution__c FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assert(!auditCase.Resolution__c.contains(noWoo.OrderNumber),
            'case resolution must not store the Salesforce internal order auto-number');
    }

    @isTest
    static void testOrderStatusNamesExistingOpenCaseSeparatelyFromAuditCase() {
        Account a = [SELECT Id, PersonContactId FROM Account WHERE PersonEmail = 'svc@example.com' LIMIT 1];
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        Case existing = new Case(
            AccountId = a.Id,
            ContactId = a.PersonContactId,
            Order__c = o.Id,
            Woo_Order_Id__c = '99001',
            Origin = 'Chat',
            Status = 'New',
            Priority = 'Medium',
            Category__c = 'Returns',
            Subject = 'Return started — order #99001'
        );
        insert existing;
        existing = [SELECT CaseNumber FROM Case WHERE Id = :existing.Id];

        OrderStatusService.Request r = new OrderStatusService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.orderIdentifier = '#99001';
        r.chatSummary = 'Shopper asked for the return case number.';

        Test.startTest();
        OrderStatusService.Result res = OrderStatusService.get(new List<OrderStatusService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(1, res.openCaseCount, 'pre-existing open return case is counted before audit case insert');
        System.assert(res.openCaseSummary.contains(existing.CaseNumber), res.openCaseSummary);
        System.assert(res.summary.contains(existing.CaseNumber), res.summary);
        System.assert(res.summary.contains('Open support case(s)'), res.summary);
        System.assertNotEquals(existing.CaseNumber, res.caseNumber,
            'returned audit case number must stay distinct from the existing open return case');
        Case audit = [SELECT Status, Subject FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assertEquals('Closed', audit.Status, 'the current chat answer still creates a solved audit case');
        System.assertEquals('Chat service: Order status answered', audit.Subject, 'audit case remains typed as an order-status answer');
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
    static void testOpenCaseUnverifiedCreatesGuestCaseWithoutPrivateLinks() {
        CaseService.Request r = new CaseService.Request();
        r.email = 'svc@example.com';
        r.subject = 'Need help with an order';
        r.description = 'Shopper typed an email but did not sign in or pass OTP.';
        r.category = 'Order';
        r.orderIdentifier = '#99001';
        r.chatSummary = 'Guest asked for help and typed svc@example.com but was not verified.';

        Test.startTest();
        CaseService.Result res = CaseService.open(new List<CaseService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
        Case c = [SELECT AccountId, ContactId, SuppliedEmail, Order__c, Woo_Order_Id__c, Summary__c, Description
                  FROM Case WHERE Id = :res.caseId LIMIT 1];
        System.assertEquals(null, c.AccountId, 'typed email alone must not link the Person Account');
        System.assertEquals(null, c.ContactId, 'typed email alone must not link the Contact');
        System.assertEquals('svc@example.com', c.SuppliedEmail, 'typed email is retained as supplied contact info');
        System.assertEquals(null, c.Order__c, 'typed order id without verification must not link private order');
        System.assertEquals(null, c.Woo_Order_Id__c, 'typed order id without verification must not stamp Woo id');
        System.assert(!c.Summary__c.contains('99001'), 'unverified case summary must not confirm the private order id');
        System.assert(c.Description.contains('Guest asked for help'), 'case still carries the chat transcript');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :c.Id AND Subject = 'Chat transcript'],
            'guest case still gets transcript activity');
    }

    @isTest
    static void testOpenCaseVerifiedLinksAccountAndWooOrderNumber() {
        Account a = [SELECT Id, PersonContactId FROM Account WHERE PersonEmail = 'svc@example.com' LIMIT 1];
        Order o = [SELECT Id, OrderNumber FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        CaseService.Request r = new CaseService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.subject = 'Return question';
        r.description = 'Needs help returning a damaged bag.';
        r.category = 'Returns';
        r.orderIdentifier = '#99001';
        r.chatSummary = 'Verified shopper asked for help with Woo order #99001.';

        Test.startTest();
        CaseService.Result res = CaseService.open(new List<CaseService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
        Case c = [SELECT AccountId, ContactId, SuppliedEmail, Order__c, Woo_Order_Id__c, Summary__c
                  FROM Case WHERE Id = :res.caseId LIMIT 1];
        System.assertEquals(a.Id, c.AccountId, 'verified case links the Person Account');
        System.assertEquals(a.PersonContactId, c.ContactId, 'verified case links the Contact');
        System.assertEquals('svc@example.com', c.SuppliedEmail, 'supplied email remains visible');
        System.assertEquals(o.Id, c.Order__c, 'verified case links the scoped order');
        System.assertEquals('99001', c.Woo_Order_Id__c, 'verified case stamps Woo order id');
        System.assert(c.Summary__c.contains('order #99001'), c.Summary__c);
        System.assert(!c.Summary__c.contains(o.OrderNumber), 'summary must not expose Salesforce internal order number');
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
    static void testCaseTranscriptStripsPreActionCaseCreatedClaim() {
        CaseService.Request r = new CaseService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.subject = 'Stale coffee';
        r.category = 'Product';
        r.description = 'Coffee arrived stale.';
        r.orderIdentifier = '#99001';
        r.chatSummary = 'Shopper said the coffee arrived stale and requested a case. Prior open case: 00001061 (Returns, New): Return started. Case 00001071 created.';

        Test.startTest();
        CaseService.Result res = CaseService.open(new List<CaseService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
        Case c = [SELECT Description FROM Case WHERE Id = :res.caseId LIMIT 1];
        System.assert(c.Description.contains('Prior open case: 00001061'), 'legitimate prior-case context remains');
        System.assert(!c.Description.contains('Case 00001071 created'), 'pre-action stale case-created claim is stripped');
        Task transcript = [SELECT Description FROM Task WHERE WhatId = :res.caseId AND Subject = 'Chat transcript' LIMIT 1];
        System.assert(!transcript.Description.contains('Case 00001071 created'), 'timeline transcript is sanitized too');
    }

    @isTest
    static void testCaseResolutionRequiresConfirmationThenCloses() {
        CaseService.Request openReq = new CaseService.Request();
        openReq.email = 'svc@example.com';
        openReq.verifiedEmail = 'svc@example.com';
        openReq.subject = 'Shipping question';
        openReq.category = 'Shipping';
        CaseService.Result opened = CaseService.open(new List<CaseService.Request>{ openReq })[0];

        CaseResolutionService.Request needsConfirm = new CaseResolutionService.Request();
        needsConfirm.caseNumber = opened.caseNumber;
        needsConfirm.resolution = 'Explained shipped vs delivered and sent tracking.';
        needsConfirm.chatSummary = 'Shopper asked why tracking showed shipped but not delivered. Agent explained the distinction and shared tracking.';
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
        Case c = [SELECT Id, Status, Resolution__c, Resolved_By__c, Description FROM Case WHERE CaseNumber = :opened.caseNumber];
        System.assertEquals('Closed', c.Status, 'case closed after explicit confirmation');
        System.assert(c.Resolution__c.contains('tracking'), 'resolution stored');
        System.assert(c.Resolved_By__c.contains('Chat Agent'), 'resolver stamped');
        System.assert(c.Description.contains('Resolution details'), 'resolution details appended to case');
        System.assert(c.Description.contains('Shopper asked why tracking'), 'chat transcript appended to case');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :c.Id AND Subject = 'Chat transcript'],
            'transcript activity logged on close');
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
        r.chatSummary = 'Shopper asked to return all items from #99001 because the package arrived damaged. Agent showed the items and shopper confirmed.';
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        ReturnService.Result duplicate = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(true, duplicate.success, duplicate.message);
        System.assertNotEquals(res.caseNumber, duplicate.caseNumber,
            'duplicate/existing-return follow-up gets its own solved service case');
        Case duplicateCase = [SELECT Status, Subject, Resolution__c FROM Case WHERE CaseNumber = :duplicate.caseNumber LIMIT 1];
        System.assertEquals('Closed', duplicateCase.Status, 'duplicate/existing-return follow-up case is closed');
        System.assertEquals('Chat service: Return status answered', duplicateCase.Subject);
        System.assert(duplicateCase.Resolution__c.contains('no duplicate return was created'),
            'duplicate return resolution is explicit');
        System.assert(res.message.contains('order #99001'), res.message);
        System.assertEquals(false, res.refundIssued, 'return start must not refund before merchandise is received');
        Order sourceOrder = [SELECT OrderNumber FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        System.assert(!res.message.contains(sourceOrder.OrderNumber),
            'return confirmation must not expose the Salesforce internal order auto-number');
        System.assertEquals(true, res.labelEmailed, 'return label email is sent in test context');
        System.assertEquals(1, [SELECT count() FROM ReturnOrder], 'ReturnOrder created');
        System.assertEquals(2, [SELECT count() FROM ReturnOrderLineItem], 'lines created');
        ReturnOrder ro = [SELECT Status, Refund_Amount__c, Woo_Refund_Id__c FROM ReturnOrder LIMIT 1];
        System.assertEquals('Submitted', ro.Status, 'return waits for receipt');
        System.assertEquals(null, ro.Woo_Refund_Id__c, 'no Woo refund at return start');
        Order after = [SELECT Fulfillment_Status__c, Payment_Status__c, Woo_Refund_Id__c FROM Order WHERE Woo_Order_Id__c = '99001'];
        System.assertEquals('Return Pending', after.Fulfillment_Status__c, 'order is waiting for merchandise receipt, not returned/refunded');
        System.assertEquals(null, after.Woo_Refund_Id__c, 'order has no refund id until receipt');
        Account a = [SELECT Has_Returned_Order__c, Return_Count__c FROM Account WHERE PersonEmail = 'svc@example.com'];
        System.assertEquals(true, a.Has_Returned_Order__c, 'flagged returned');
        System.assertEquals(1, a.Return_Count__c, 'return count incremented');
        Case rc = [SELECT Id, Description FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assert(rc.Description.contains('Chat transcript'), 'return case carries chat transcript');
        System.assert(rc.Description.contains('package arrived damaged'), 'return case stores shopper reason transcript');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :rc.Id AND Subject = 'Chat transcript'],
            'return transcript activity logged on case timeline');
        // Winback_Needed__c was set true then cleared by the async Winback_On_Return flow at stopTest.
    }

    @isTest
    static void testPartialQuantityReturnStartsPendingRefund() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnService.Request r = new ReturnService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.orderIdentifier = '99001';
        r.reason = 'Quality';
        r.itemsToReturn = '1 x Test Bean';
        r.confirmed = true;
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(false, res.refundIssued, 'partial return still waits for receipt');
        System.assertEquals(20, res.refundAmount, 'one of two bean bags is a partial refund amount');
        List<ReturnOrderLineItem> lines = [
            SELECT OrderItemId, QuantityReturned, QuantityExpected, UnitPrice, Woo_Line_Item_Id__c
            FROM ReturnOrderLineItem
        ];
        System.assertEquals(1, lines.size(), 'only selected product line returned');
        System.assertNotEquals(null, lines[0].OrderItemId, 'return line points back to the source order product');
        System.assertEquals(1, lines[0].QuantityReturned, 'only one bag returned');
        System.assertEquals('101', lines[0].Woo_Line_Item_Id__c, 'Woo line id copied for line-level refund');
    }

    @isTest
    static void testReturnMessageSurfacesLabelEmailFailure() {
        Test.setMock(HttpCalloutMock.class, new WooLabelEmailFailMock());
        WooOrderActionService.allowHttpInTests = true;
        ReturnService.forceLabelBackupFailureInTests = true;
        lastLabelEmailEndpoint = null;
        lastLabelEmailBody = null;

        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnService.Request r = new ReturnService.Request();
        r.email = 'svc@example.com';
        r.verifiedEmail = 'svc@example.com';
        r.orderIdentifier = '99001';
        r.reason = 'Quality';
        r.confirmed = true;
        Test.startTest();
        ReturnService.Result res = ReturnService.process(new List<ReturnService.Request>{ r })[0];
        Test.stopTest();
        WooOrderActionService.allowHttpInTests = false;
        ReturnService.forceLabelBackupFailureInTests = false;

        System.assertEquals(true, res.success, res.message);
        System.assertEquals(false, res.labelEmailed, 'action must expose that neither email path delivered');
        System.assert(res.message.contains('label email could not be sent automatically'), res.message);
        System.assert(res.message.contains(res.returnLabelUrl), 'shopper still gets the label link inline');
        System.assert(lastLabelEmailEndpoint != null && lastLabelEmailEndpoint.endsWith('/wp-json/kwitko/v1/return-label-email'),
            'Woo label endpoint was attempted before falling back');
    }

    @isTest
    static void testReceiveReturnIssuesWooRefundAndClosesCase() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnService.Request startReq = new ReturnService.Request();
        startReq.email = 'svc@example.com';
        startReq.verifiedEmail = 'svc@example.com';
        startReq.orderIdentifier = '99001';
        startReq.reason = 'Damaged';
        startReq.confirmed = true;
        Test.startTest();
        ReturnService.Result started = ReturnService.process(new List<ReturnService.Request>{ startReq })[0];
        List<ReturnOrderLineItem> staleLines = [
            SELECT Id
            FROM ReturnOrderLineItem
            WHERE ReturnOrder.ReturnOrderNumber = :started.returnOrderNumber
        ];
        for (ReturnOrderLineItem line : staleLines) {
            line.OrderItemId = null;
            line.Woo_Line_Item_Id__c = null;
        }
        update staleLines;
        ReturnReceiptService.Request receiveReq = new ReturnReceiptService.Request();
        receiveReq.returnOrderNumber = started.returnOrderNumber;
        receiveReq.receivedNote = 'Warehouse received all bags in resellable condition.';
        receiveReq.confirmed = true;
        ReturnReceiptService.Result received = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ receiveReq })[0];
        ReturnReceiptService.Request idempotentReq = new ReturnReceiptService.Request();
        idempotentReq.orderIdentifier = '99001';
        idempotentReq.confirmed = true;
        ReturnReceiptService.Result idempotent = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ idempotentReq })[0];
        Test.stopTest();

        System.assertEquals(true, received.success, received.message);
        System.assertEquals(true, idempotent.success, idempotent.message);
        System.assert(idempotent.message.contains('already closed'), 'second receipt call is idempotent');
        System.assertEquals(started.caseNumber, idempotent.caseNumber, 'idempotent receipt returns the closed Returns case number');
        System.assertEquals(true, received.refundIssued, 'refund issued only after receipt');
        ReturnOrder ro = [SELECT Status, Woo_Refund_Id__c FROM ReturnOrder WHERE ReturnOrderNumber = :started.returnOrderNumber];
        System.assertEquals('Closed', ro.Status, 'return closed after receipt');
        System.assertEquals('test-refund', ro.Woo_Refund_Id__c, 'Woo refund id stored');
        Order after = [SELECT Fulfillment_Status__c, Payment_Status__c, Woo_Refund_Id__c FROM Order WHERE Woo_Order_Id__c = '99001'];
        System.assertEquals('Refunded', after.Fulfillment_Status__c, 'order lifecycle updated after Woo refund');
        System.assertEquals('Refunded', after.Payment_Status__c, 'payment status updated after Woo refund');
        System.assertEquals('test-refund', after.Woo_Refund_Id__c, 'order stores Woo refund id');
        Case c = [SELECT Status, Resolution__c, Description FROM Case WHERE CaseNumber = :started.caseNumber];
        System.assertEquals('Closed', c.Status, 'returns case closed after merchandise receipt');
        System.assert(c.Resolution__c.contains('WooCommerce refund test-refund'), 'case resolution records refund');
        System.assert(c.Description.contains('Return receipt resolution'), 'case description carries receipt details');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :c.Id AND Subject = 'Return received and refund processed'],
            'receipt activity is logged on case timeline');
        for (ReturnOrderLineItem line : [SELECT QuantityReturned, QuantityReceived, OrderItemId, Woo_Line_Item_Id__c FROM ReturnOrderLineItem]) {
            System.assertEquals(line.QuantityReturned, line.QuantityReceived, 'received qty stamped');
            System.assertNotEquals(null, line.OrderItemId, 'receipt backfills source order product');
            System.assertNotEquals(null, line.Woo_Line_Item_Id__c, 'receipt backfills Woo line id');
        }
    }

    @isTest
    static void testReceiveReturnCreatesClosedAuditCaseWhenCaseMissing() {
        Account a = [SELECT Id, PersonContactId FROM Account WHERE PersonEmail = 'svc@example.com' LIMIT 1];
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        Product2 bean = [SELECT Id FROM Product2 WHERE Name = 'Test Bean' LIMIT 1];
        OrderItem oi = [SELECT Id, Woo_Line_Item_Id__c FROM OrderItem WHERE OrderId = :o.Id AND Product2Id = :bean.Id LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnOrder ro = new ReturnOrder(
            AccountId = a.Id,
            Order__c = o.Id,
            Return_Reason__c = 'Quality',
            Refund_Amount__c = 20,
            Status = 'Submitted',
            Return_Tracking__c = 'KWRET99001'
        );
        insert ro;
        insert new ReturnOrderLineItem(
            ReturnOrderId = ro.Id,
            Product2Id = bean.Id,
            OrderItemId = oi.Id,
            QuantityReturned = 1,
            QuantityExpected = 1,
            UnitPrice = 20,
            ReasonForReturn = 'Not Satisfied',
            RepaymentMethod = 'Refund',
            Woo_Line_Item_Id__c = oi.Woo_Line_Item_Id__c
        );

        ReturnReceiptService.Request receiveReq = new ReturnReceiptService.Request();
        receiveReq.returnTracking = 'KWRET99001';
        receiveReq.receivedNote = 'Warehouse receipt arrived without an existing Salesforce case.';
        receiveReq.confirmed = true;

        Test.startTest();
        ReturnReceiptService.Result received = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ receiveReq })[0];
        Test.stopTest();

        System.assertEquals(true, received.success, received.message);
        System.assertEquals(true, received.refundIssued, 'refund should issue after confirmed receipt');
        System.assert(String.isNotBlank(received.caseNumber), 'missing case fallback should create an audit case');
        Case c = [
            SELECT Id, Status, Category__c, Origin, Resolution__c, Description
            FROM Case
            WHERE CaseNumber = :received.caseNumber
            LIMIT 1
        ];
        System.assertEquals('Closed', c.Status, 'fallback receipt case is closed because the interaction is solved');
        System.assertEquals('Returns', c.Category__c, 'fallback case is a returns case');
        System.assertEquals('WooCommerce', c.Origin, 'fallback case records the supply-chain source');
        System.assert(c.Resolution__c.contains('WooCommerce refund test-refund'), 'refund id is recorded on fallback case');
        System.assert(c.Description.contains('Warehouse receipt arrived without an existing Salesforce case'),
            'receipt note is preserved on fallback case');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :c.Id AND Subject = 'Return received and refund processed'],
            'fallback case gets a receipt activity on the timeline');
    }

    @isTest
    static void testReceiveReturnWooRefundFailureOpensFollowupCase() {
        Test.setMock(HttpCalloutMock.class, new WooRefundFailMock());
        WooOrderActionService.allowHttpInTests = true;
        Account a = [SELECT Id FROM Account WHERE PersonEmail = 'svc@example.com' LIMIT 1];
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '99001' LIMIT 1];
        Product2 bean = [SELECT Id FROM Product2 WHERE Name = 'Test Bean' LIMIT 1];
        OrderItem oi = [SELECT Id, Woo_Line_Item_Id__c FROM OrderItem WHERE OrderId = :o.Id AND Product2Id = :bean.Id LIMIT 1];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ReturnOrder ro = new ReturnOrder(
            AccountId = a.Id,
            Order__c = o.Id,
            Return_Reason__c = 'Quality',
            Refund_Amount__c = 20,
            Status = 'Submitted',
            Return_Tracking__c = 'KWRETFAIL'
        );
        insert ro;
        insert new ReturnOrderLineItem(
            ReturnOrderId = ro.Id,
            Product2Id = bean.Id,
            OrderItemId = oi.Id,
            QuantityReturned = 1,
            QuantityExpected = 1,
            UnitPrice = 20,
            ReasonForReturn = 'Not Satisfied',
            RepaymentMethod = 'Refund',
            Woo_Line_Item_Id__c = oi.Woo_Line_Item_Id__c
        );

        ReturnReceiptService.Request receiveReq = new ReturnReceiptService.Request();
        receiveReq.returnTracking = 'KWRETFAIL';
        receiveReq.receivedNote = 'Warehouse received it, but Woo refund failed.';
        receiveReq.confirmed = true;

        Test.startTest();
        ReturnReceiptService.Result received = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ receiveReq })[0];
        Test.stopTest();
        WooOrderActionService.allowHttpInTests = false;

        System.assertEquals(false, received.success, 'failed Woo refund cannot be reported as solved');
        System.assert(String.isNotBlank(received.caseNumber), 'Woo refund failure opens a follow-up case');
        Case c = [SELECT Status, Priority, Description FROM Case WHERE CaseNumber = :received.caseNumber LIMIT 1];
        System.assertEquals('New', c.Status, 'refund failure case remains open');
        System.assertEquals('High', c.Priority, 'failed money-moving action is high priority');
        System.assert(c.Description.contains('WooCommerce refund failed'), 'case records the Woo failure');
        ReturnOrder after = [SELECT Status, Woo_Refund_Id__c FROM ReturnOrder WHERE Id = :ro.Id LIMIT 1];
        System.assertEquals('Submitted', after.Status, 'return stays open until refund succeeds');
        System.assertEquals(null, after.Woo_Refund_Id__c, 'failed refund id is not stamped');
    }

    @isTest
    static void testReceiveReturnRequiresConfirmation() {
        ReturnReceiptService.Request r = new ReturnReceiptService.Request();
        r.orderIdentifier = '99001';
        ReturnReceiptService.Result res = ReturnReceiptService.receive(new List<ReturnReceiptService.Request>{ r })[0];
        System.assertEquals(false, res.success, 'receipt/refund requires explicit confirmation');
        System.assert(res.message.contains('Confirm'), 'clear confirmation message');
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
        r.chatSummary = 'Shopper asked to cancel order #99001 because they changed their mind. Agent confirmed before cancelling and refunding.';
        Test.startTest();
        CancellationService.Result res = CancellationService.cancel(new List<CancellationService.Request>{ r })[0];
        CancellationService.Result already = CancellationService.cancel(new List<CancellationService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(true, already.success, already.message);
        System.assert(String.isNotBlank(already.caseNumber), 'already-cancelled answer still creates an audit case');
        Order o = [SELECT Fulfillment_Status__c FROM Order WHERE Woo_Order_Id__c = '99001'];
        System.assertEquals('Cancelled', o.Fulfillment_Status__c, 'order cancelled');
        Case c = [SELECT Id, Status, Resolution__c, Description FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assertEquals('Closed', c.Status, 'completed cancellation case is closed');
        System.assert(c.Resolution__c.contains('refund issued'), 'closed cancellation case records refund resolution');
        System.assert(c.Description.contains('Chat transcript'), 'cancellation case carries chat transcript');
        System.assert(c.Description.contains('changed their mind'), 'cancellation case stores shopper transcript');
        Case alreadyCase = [SELECT Status, Resolution__c FROM Case WHERE CaseNumber = :already.caseNumber LIMIT 1];
        System.assertEquals('Closed', alreadyCase.Status, 'already-cancelled answer is a solved audit case');
        System.assert(alreadyCase.Resolution__c.contains('already cancelled'), 'already-cancelled resolution is explicit');
        System.assertEquals(1, [SELECT count() FROM Task WHERE WhatId = :c.Id AND Subject = 'Chat transcript'],
            'cancellation transcript activity logged on case timeline');
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
        System.assert(String.isNotBlank(res.caseNumber), 'ineligible cancellation still creates an audit case');
        Case c = [SELECT Status, Resolution__c FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assertEquals('Closed', c.Status, 'ineligible cancellation is a solved answer case');
        System.assert(c.Resolution__c.contains('can no longer be cancelled'), 'resolution explains the denial');
    }

    @isTest
    static void testCancelWooFailureDoesNotRefundOrMutateOrder() {
        Test.setMock(HttpCalloutMock.class, new WooCancelFailMock());
        WooOrderActionService.allowHttpInTests = true;
        lastRefundEndpoint = null;
        lastRefundBody = null;
        CancellationService.Request r = new CancellationService.Request();
        r.email = 'svc@example.com'; r.verifiedEmail = 'svc@example.com'; r.orderIdentifier = '99001';
        r.reason = 'Changed mind'; r.confirmed = true;
        r.chatSummary = 'Shopper asked to cancel, but WooCommerce rejected the cancellation.';
        Test.startTest();
        CancellationService.Result res = CancellationService.cancel(new List<CancellationService.Request>{ r })[0];
        Test.stopTest();
        WooOrderActionService.allowHttpInTests = false;

        System.assertEquals(false, res.success, 'failed Woo cancellation is not reported as solved');
        System.assertEquals(null, lastRefundEndpoint, 'refund is not attempted when Woo cancellation fails');
        Order unchanged = [SELECT Fulfillment_Status__c, Woo_Refund_Id__c FROM Order WHERE Woo_Order_Id__c = '99001'];
        System.assertEquals('Not Shipped', unchanged.Fulfillment_Status__c, 'Salesforce order is not marked cancelled');
        System.assertEquals(null, unchanged.Woo_Refund_Id__c, 'no refund id is stamped');
        Case c = [SELECT Status, Priority, Description FROM Case WHERE CaseNumber = :res.caseNumber LIMIT 1];
        System.assertEquals('New', c.Status, 'failed cancellation needs human follow-up');
        System.assertEquals('High', c.Priority, 'failed money-moving action is high priority');
        System.assert(c.Description.contains('no refund was attempted'), 'case explains the safe failure');
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
        WooOrderActionService.WooResult lineRefund = WooOrderActionService.refundOrder('123', 5, 'partial',
            new List<WooOrderActionService.RefundLine>{ new WooOrderActionService.RefundLine('101', 5) });
        WooOrderActionService.WooResult verificationEmail = WooOrderActionService.sendVerificationCodeEmail(
            'svc@example.com', '123456', 10);
        WooOrderActionService.WooResult note = WooOrderActionService.addCustomerNote('123', 'label note', true);
        Test.stopTest();
        System.assertEquals(true, cancel.success, 'test-context cancel ok');
        System.assertEquals(true, refund.success, 'test-context refund ok');
        System.assertEquals(true, lineRefund.success, 'test-context line refund ok');
        System.assertEquals(true, verificationEmail.success, 'test-context verification email ok');
        System.assertEquals(true, note.success, 'test-context note ok');
    }

    @isTest
    static void testWooOrderActionServiceHttpBranchesWithMock() {
        Test.setMock(HttpCalloutMock.class, new WooActionMock());
        WooOrderActionService.allowHttpInTests = true;
        Test.startTest();
        WooOrderActionService.WooResult cancel = WooOrderActionService.cancelOrder('123');
        Boolean address = WooOrderActionService.updateShippingAddress('123', '1 Test', 'Austin', 'TX', '78701', 'US');
        WooOrderActionService.WooResult refund = WooOrderActionService.refundOrder('123', 7, 'partial return',
            new List<WooOrderActionService.RefundLine>{ new WooOrderActionService.RefundLine('101', 7) });
        WooOrderActionService.WooResult labelEmail = WooOrderActionService.sendReturnLabelEmail(
            '123', 'svc@example.com', '#123', 'https://example.com/return-label', 'KWRET123', '1× Test Bean');
        WooOrderActionService.WooResult verificationEmail = WooOrderActionService.sendVerificationCodeEmail(
            'svc@example.com', '654321', 10);
        WooOrderActionService.WooResult note = WooOrderActionService.addCustomerNote('123', 'label note', true);
        Test.stopTest();
        WooOrderActionService.allowHttpInTests = false;
        System.assertEquals(true, cancel.success, cancel.message);
        System.assertEquals(true, address, 'address update branch parsed success');
        System.assertEquals(true, refund.success, refund.message);
        System.assertEquals('77701', refund.refundId, 'refund id parsed from Woo response');
        System.assert(lastRefundBody.contains('"line_items"'), 'line-level refund payload sent to Woo');
        System.assert(lastRefundBody.contains('"id":101'), 'Woo line item id included in refund payload');
        System.assert(lastRefundBody.contains('"refund_total":"7.00"'), 'line refund total included in refund payload');
        System.assertEquals(true, labelEmail.success, labelEmail.message);
        System.assert(lastLabelEmailEndpoint != null && lastLabelEmailEndpoint.endsWith('/wp-json/kwitko/v1/return-label-email'),
            'return-label email endpoint targets the storefront route');
        System.assert(lastLabelEmailBody.contains('"to_email":"svc@example.com"'), lastLabelEmailBody);
        System.assert(lastLabelEmailBody.contains('"tracking":"KWRET123"'), lastLabelEmailBody);
        System.assertEquals(true, verificationEmail.success, verificationEmail.message);
        System.assert(lastVerificationEmailEndpoint != null && lastVerificationEmailEndpoint.endsWith('/wp-json/kwitko/v1/verification-code-email'),
            'verification email endpoint targets the storefront route');
        System.assert(lastVerificationEmailBody.contains('"code":"654321"'), lastVerificationEmailBody);
        System.assertEquals(true, note.success, note.message);
        System.assertEquals('77802', note.noteId, 'order note id parsed from Woo response');
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
