/**
 * ServiceFixToolsTest — certification coverage for the C1/C2/C3 build:
 *  - IdentityService PII gate (verified vs unverified)
 *  - the 8 service "fix" tools (tracking, address, failed-payment, password reset, callback,
 *    reship, modify, exchange) including identity refusal + eligibility paths
 *  - WooOrderService two-way reconcile (Woo-side cancellation/refund/fulfillment flowing back).
 */
@isTest
private class ServiceFixToolsTest {

    private static final String EMAIL = 'fixtools@example.com';

    private class WooCouponMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":4567}');
            return res;
        }
    }

    private static Product2 mkProd(String name, String family) {
        return new Product2(Name = name, Family = family, IsActive = true,
            Stock_On_Hand__c = 50, Woo_Product_Id__c = String.valueOf(Math.abs(name.hashCode())));
    }

    @testSetup
    static void setup() {
        Product2 bean = mkProd('Fix Bean', 'Single-Origin');
        Product2 gear = mkProd('Fix Grinder', 'Grinders');
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
        Account a = new Account(RecordTypeId = rt, FirstName = 'Fix', LastName = 'Tester',
            PersonEmail = EMAIL, Email_Consent__c = true);
        insert a;

        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = stdPb, Woo_Order_Id__c = '88001', Source__c = 'Ecommerce',
            Fulfillment_Status__c = 'Not Shipped',
            ShippingStreet = '1 Old St', ShippingCity = 'Austin', ShippingStateCode = 'TX',
            ShippingPostalCode = '73301', ShippingCountryCode = 'US');
        insert o;
        insert new List<OrderItem>{
            new OrderItem(OrderId = o.Id, Product2Id = bean.Id, PricebookEntryId = byProd.get(bean.Id).Id, Quantity = 2, UnitPrice = 20),
            new OrderItem(OrderId = o.Id, Product2Id = gear.Id, PricebookEntryId = byProd.get(gear.Id).Id, Quantity = 1, UnitPrice = 20)
        };
    }

    // ───────────────────────── Identity gate ─────────────────────────
    @isTest
    static void identityGate() {
        System.assertEquals(true, IdentityService.isVerified('A@b.com', 'a@b.com'), 'case-insensitive match verifies');
        System.assertEquals(false, IdentityService.isVerified('a@b.com', ''), 'blank verified => not verified');
        System.assertEquals(false, IdentityService.isVerified('a@b.com', 'other@b.com'), 'mismatch => not verified');
        System.assertEquals(false, IdentityService.isVerified('', 'a@b.com'), 'blank requested => not verified');
        System.assert(IdentityService.signInMessage().contains(IdentityService.LOGIN_URL), 'sign-in msg has login link');
    }

    @isTest
    static void trackingUnverifiedRefused() {
        TrackingService.Request r = new TrackingService.Request();
        r.email = EMAIL; // no verifiedEmail => not verified
        TrackingService.Result res = TrackingService.get(new List<TrackingService.Request>{ r })[0];
        System.assertEquals(false, res.found, 'no tracking leaked to unverified shopper');
        System.assert(res.message.contains(IdentityService.LOGIN_URL), 'returns sign-in message');
    }

    @isTest
    static void trackingVerified() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Shipped',
            Tracking_Number__c = '1Z999', Carrier__c = 'UPS', Tracking_Url__c = 'https://t/1Z999');
        TrackingService.Request r = new TrackingService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        TrackingService.Result res = TrackingService.get(new List<TrackingService.Request>{ r })[0];
        System.assertEquals(true, res.found, 'tracking returned for verified shopper');
        System.assertEquals('1Z999', res.trackingNumber, 'tracking number surfaced');
        System.assert(res.message.contains('UPS'), 'carrier in message');
    }

    @isTest
    static void trackingNoneYet() {
        TrackingService.Request r = new TrackingService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        TrackingService.Result res = TrackingService.get(new List<TrackingService.Request>{ r })[0];
        System.assertEquals(false, res.found, 'no tracking yet');
        System.assert(res.message.contains('No tracking number'), 'explains none available');
    }

    // ───────────────────────── Address update ─────────────────────────
    @isTest
    static void addressUpdatePreShip() {
        AddressUpdateService.Request r = new AddressUpdateService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        r.street = '99 New Ave'; r.city = 'Dallas'; r.stateCode = 'TX'; r.postalCode = '75001'; r.countryCode = 'US'; r.confirmed = true;
        Test.startTest();
        AddressUpdateService.Result res = AddressUpdateService.run(new List<AddressUpdateService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        Order o = [SELECT ShippingStreet, ShippingCity FROM Order WHERE Woo_Order_Id__c = '88001'];
        System.assertEquals('99 New Ave', o.ShippingStreet, 'street updated in SF');
        System.assertEquals('Dallas', o.ShippingCity, 'city updated');
    }

    @isTest
    static void addressUpdateBlockedAfterShip() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Shipped');
        AddressUpdateService.Request r = new AddressUpdateService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.street = 'x';
        AddressUpdateService.Result res = AddressUpdateService.run(new List<AddressUpdateService.Request>{ r })[0];
        System.assertEquals(false, res.success, 'cannot change address once shipped');
        System.assert(res.message.contains('Shipped'), 'explains why');
    }

    // ───────────────────────── Failed payment ─────────────────────────
    @isTest
    static void failedPaymentIssuesLink() {
        FailedPaymentService.Request r = new FailedPaymentService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        Test.startTest();
        FailedPaymentService.Result res = FailedPaymentService.run(new List<FailedPaymentService.Request>{ r })[0];
        Test.stopTest();
        System.assert(String.isNotBlank(res.payUrl), 'pay-now link issued');
        System.assert(String.isNotBlank(res.caseNumber), 'billing case opened');
        System.assertEquals(1, [SELECT count() FROM Case WHERE Category__c = 'Billing'], 'billing case exists');
    }

    @isTest
    static void failedPaymentAlreadyPaid() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        update new Order(Id = o.Id, Payment_Status__c = 'Paid');
        FailedPaymentService.Request r = new FailedPaymentService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        FailedPaymentService.Result res = FailedPaymentService.run(new List<FailedPaymentService.Request>{ r })[0];
        System.assertEquals(true, res.success, 'paid path succeeds');
        System.assert(res.message.contains('already paid'), 'tells shopper it is paid');
    }

    // ───────────────────────── Password reset (no verification needed) ─────────────────────────
    @isTest
    static void passwordResetLink() {
        PasswordResetService.Request r = new PasswordResetService.Request();
        r.email = EMAIL;
        PasswordResetService.Result res = PasswordResetService.run(new List<PasswordResetService.Request>{ r })[0];
        System.assertEquals(true, res.success, 'always returns a reset link');
        System.assert(res.resetUrl.contains('lost-password'), 'is the reset URL');
    }

    // ───────────────────────── Callback ─────────────────────────
    @isTest
    static void callbackCreatesCaseAndTask() {
        CallbackService.Request r = new CallbackService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.reason = 'Wrong roast'; r.preferredTime = 'tomorrow AM';
        Test.startTest();
        CallbackService.Result res = CallbackService.run(new List<CallbackService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(1, [SELECT count() FROM Case WHERE Subject = 'Callback request'], 'callback case');
        System.assertEquals(1, [SELECT count() FROM Task WHERE Subject LIKE 'Call back%'], 'callback task');
    }

    // ───────────────────────── Store credit ─────────────────────────
    @isTest
    static void storeCreditRequiresVerificationAndConfirmation() {
        StoreCreditService.Request unverified = new StoreCreditService.Request();
        unverified.email = EMAIL;
        unverified.amount = 12;
        unverified.reason = 'Delay';
        StoreCreditService.Result blockedIdentity = StoreCreditService.apply(
            new List<StoreCreditService.Request>{ unverified })[0];
        System.assertEquals(false, blockedIdentity.success, 'store credit does not issue to unverified identity');
        System.assert(blockedIdentity.message.contains(IdentityService.LOGIN_URL), 'sign-in gate returned');

        StoreCreditService.Request needsConfirm = new StoreCreditService.Request();
        needsConfirm.email = EMAIL;
        needsConfirm.verifiedEmail = EMAIL;
        needsConfirm.amount = 12;
        needsConfirm.reason = 'Delay';
        StoreCreditService.Result blockedConfirm = StoreCreditService.apply(
            new List<StoreCreditService.Request>{ needsConfirm })[0];
        System.assertEquals(false, blockedConfirm.success, 'store credit waits for shopper acceptance');
        System.assert(blockedConfirm.message.contains('confirm'), 'confirmation prompt returned');
    }

    @isTest
    static void storeCreditIssuesCouponWhenConfirmed() {
        Test.setMock(HttpCalloutMock.class, new WooCouponMock());
        StoreCreditService.Request r = new StoreCreditService.Request();
        r.email = EMAIL;
        r.verifiedEmail = EMAIL;
        r.amount = 75;
        r.reason = 'Carrier delay';
        r.confirmed = true;

        Test.startTest();
        StoreCreditService.Result res = StoreCreditService.apply(new List<StoreCreditService.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
        System.assertEquals(50, res.amount, 'AI-issued credit is capped');
        System.assert(String.isNotBlank(res.couponCode), 'coupon code returned');
        System.assertEquals(1, [SELECT count() FROM Coupon__c WHERE Code__c = :res.couponCode], 'coupon recorded in CRM');
        System.assertEquals(1, [SELECT count() FROM Agent_Interaction__c WHERE Action__c = 'apply_store_credit'], 'journey log recorded');
    }

    // ───────────────────────── Reship ─────────────────────────
    @isTest
    static void reshipCreatesFreeReplacement() {
        ReshipService.Request r = new ReshipService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001'; r.reason = 'Damaged in transit'; r.confirmed = true;
        Test.startTest();
        ReshipService.Result res = ReshipService.run(new List<ReshipService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(2, [SELECT count() FROM Order], 'original + replacement');
        // OrderNumber (auto-number) can collide within a single test transaction, so identify the
        // replacement by its distinguishing Source__c = 'Manual' (the original is 'Ecommerce').
        Order rep = [SELECT Id, Source__c FROM Order WHERE Source__c = 'Manual' LIMIT 1];
        System.assertEquals('Manual', rep.Source__c, 'replacement is manual');
        System.assertEquals(2, [SELECT count() FROM OrderItem WHERE OrderId = :rep.Id], 'items cloned');
        for (OrderItem oi : [SELECT UnitPrice FROM OrderItem WHERE OrderId = :rep.Id]) {
            System.assertEquals(0, oi.UnitPrice, 'replacement items are free');
        }
        System.assert(String.isNotBlank(res.caseNumber), 'reship case opened');
    }

    // ───────────────────────── Modify order ─────────────────────────
    @isTest
    static void modifyOrderPreShip() {
        OrderModifyService.Request r = new OrderModifyService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001'; r.change = 'Add 1 more bean bag'; r.confirmed = true;
        Test.startTest();
        OrderModifyService.Result res = OrderModifyService.run(new List<OrderModifyService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(1, [SELECT count() FROM Case WHERE Subject LIKE 'Modify order%'], 'modify case');
    }

    @isTest
    static void modifyOrderBlockedAfterShip() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        OrderModifyService.Request r = new OrderModifyService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.change = 'x';
        OrderModifyService.Result res = OrderModifyService.run(new List<OrderModifyService.Request>{ r })[0];
        System.assertEquals(false, res.success, 'cannot modify a delivered order');
    }

    // ───────────────────────── Exchange (delivered) ─────────────────────────
    @isTest
    static void exchangeOnDelivered() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered');
        ExchangeService.Request r = new ExchangeService.Request();
        r.email = EMAIL; r.verifiedEmail = EMAIL; r.orderIdentifier = '88001';
        r.reason = 'Wrong grind'; r.desiredItem = 'Whole bean instead'; r.confirmed = true;
        Test.startTest();
        ExchangeService.Result res = ExchangeService.run(new List<ExchangeService.Request>{ r })[0];
        Test.stopTest();
        System.assertEquals(true, res.success, res.message);
        System.assertEquals(1, [SELECT count() FROM ReturnOrder], 'return leg created');
        System.assert(String.isNotBlank(res.caseNumber), 'exchange case opened');
    }

    @isTest
    static void exchangeRefusedUnverified() {
        ExchangeService.Request r = new ExchangeService.Request();
        r.email = EMAIL; // not verified
        ExchangeService.Result res = ExchangeService.run(new List<ExchangeService.Request>{ r })[0];
        System.assertEquals(false, res.success, 'unverified exchange refused');
        System.assert(res.message.contains(IdentityService.LOGIN_URL), 'sign-in message');
    }

    // ───────────────────────── Two-way reconcile (C2) ─────────────────────────
    @isTest
    static void reconcileWooCancellation() {
        Order o = [SELECT Id, Fulfillment_Status__c FROM Order WHERE Woo_Order_Id__c = '88001'];
        System.assertEquals('Not Shipped', o.Fulfillment_Status__c, 'starts not shipped');
        Map<String, Object> payload = new Map<String, Object>{
            'id' => 88001, 'status' => 'cancelled',
            'billing' => new Map<String, Object>{ 'email' => EMAIL }
        };
        Test.startTest();
        Id resultId = WooOrderService.ingestOrder(payload);
        Test.stopTest();
        System.assertEquals(o.Id, resultId, 'reconciled existing order (not a new one)');
        Order after = [SELECT Fulfillment_Status__c, Woo_Status__c, Cancellation_Source__c, Cancelled_By__c FROM Order WHERE Id = :o.Id];
        System.assertEquals('Cancelled', after.Fulfillment_Status__c, 'Woo cancel flowed back to SF');
        System.assertEquals('cancelled', after.Woo_Status__c, 'woo status stored');
        System.assertEquals('WooCommerce', after.Cancellation_Source__c, 'source is WooCommerce');
        System.assert(after.Cancelled_By__c != null && after.Cancelled_By__c.contains('WooCommerce'), 'who-cancelled traceable');
    }

    @isTest
    static void reconcileWooRefundAndPayment() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        Map<String, Object> payload = new Map<String, Object>{
            'id' => 88001, 'status' => 'refunded', 'date_paid' => '2026-01-01T10:00:00',
            'billing' => new Map<String, Object>{ 'email' => EMAIL }
        };
        Test.startTest();
        WooOrderService.ingestOrder(payload);
        Test.stopTest();
        Order after = [SELECT Fulfillment_Status__c, Payment_Status__c FROM Order WHERE Id = :o.Id];
        System.assertEquals('Refunded', after.Fulfillment_Status__c, 'refund reconciled');
        System.assertEquals('Refunded', after.Payment_Status__c, 'payment status refunded');
    }

    @isTest
    static void reconcileWooCompletedWithTrackingIsShippedNotDelivered() {
        Order o = [SELECT Id FROM Order WHERE Woo_Order_Id__c = '88001'];
        Map<String, Object> payload = new Map<String, Object>{
            'id' => 88001, 'status' => 'completed', 'date_paid' => '2026-01-01T10:00:00',
            'billing' => new Map<String, Object>{ 'email' => EMAIL },
            'meta_data' => new List<Object>{
                new Map<String, Object>{ 'key' => 'tracking_number', 'value' => '1ZCOMPLETE' }
            }
        };
        Test.startTest();
        WooOrderService.ingestOrder(payload);
        Test.stopTest();

        Order after = [SELECT Fulfillment_Status__c, Tracking_Number__c FROM Order WHERE Id = :o.Id];
        System.assertEquals('Shipped', after.Fulfillment_Status__c, 'Woo completed is shipped/fulfilled, not delivered');
        System.assertEquals('1ZCOMPLETE', after.Tracking_Number__c, 'tracking still synced');

        ReturnService.Request rr = new ReturnService.Request();
        rr.email = EMAIL; rr.verifiedEmail = EMAIL; rr.orderIdentifier = '88001'; rr.reason = 'Changed Mind';
        ReturnService.Result blocked = ReturnService.process(new List<ReturnService.Request>{ rr })[0];
        System.assertEquals(false, blocked.success, 'cannot return before shipment delivery proof');
        System.assert(blocked.message.contains('Delivered'), 'message explains delivery requirement');
    }

    @isTest
    static void ingestNewWooPurchaseCreatesCustomerOrderAndClosesLead() {
        Product2 p = [SELECT Id, Woo_Product_Id__c FROM Product2 WHERE Name = 'Fix Bean' LIMIT 1];
        insert new Lead(LastName = 'Buyer', Company = 'Web', Email = 'newbuyer@example.com',
            LeadSource = 'Website Chat', Status = 'Open - Not Contacted');

        Map<String, Object> payload = new Map<String, Object>{
            'id' => 9908802,
            'status' => 'completed',
            'date_paid' => '2026-01-01T10:00:00',
            'discount_total' => '4.00',
            'customer_id' => 222,
            'billing' => new Map<String, Object>{
                'email' => 'newbuyer@example.com',
                'first_name' => 'New',
                'last_name' => 'Buyer',
                'phone' => '555-0100'
            },
            'shipping' => new Map<String, Object>{
                'address_1' => '10 Ship St',
                'city' => 'Austin',
                'state' => 'TX',
                'postcode' => '73301',
                'country' => 'US'
            },
            'coupon_lines' => new List<Object>{
                new Map<String, Object>{ 'code' => 'HELLO' }
            },
            'line_items' => new List<Object>{
                new Map<String, Object>{
                    'product_id' => p.Woo_Product_Id__c,
                    'quantity' => 2,
                    'price' => 19
                }
            },
            'meta_data' => new List<Object>{
                new Map<String, Object>{ 'key' => 'kwitko/marketing_consent', 'value' => 'true' },
                new Map<String, Object>{
                    'key' => 'tracking_items',
                    'value' => new List<Object>{
                        new Map<String, Object>{
                            'tracking_number' => '1ZNEWBUYER',
                            'tracking_provider' => 'UPS',
                            'custom_tracking_link' => 'https://track.example/1ZNEWBUYER'
                        }
                    }
                }
            }
        };

        Test.startTest();
        Id orderId = WooOrderService.ingestOrder(payload);
        Test.stopTest();

        Account a = [SELECT Customer_Status__c, Email_Consent__c, Woo_Customer_Id__c FROM Account WHERE PersonEmail = 'newbuyer@example.com'];
        System.assertEquals('Customer', a.Customer_Status__c, 'purchase turns account into customer');
        System.assertEquals(true, a.Email_Consent__c, 'checkout consent captured');
        System.assertEquals('222', a.Woo_Customer_Id__c, 'Woo customer id stored');

        Order o = [SELECT Status, Fulfillment_Status__c, Woo_Status__c, Tracking_Number__c, Carrier__c, Coupon_Code__c
                   FROM Order WHERE Id = :orderId];
        System.assertEquals('Activated', o.Status, 'order activated after items are created');
        System.assertEquals('Shipped', o.Fulfillment_Status__c, 'Woo completed maps to shipped, not delivered');
        System.assertEquals('completed', o.Woo_Status__c, 'Woo status stored');
        System.assertEquals('1ZNEWBUYER', o.Tracking_Number__c, 'tracking number extracted');
        System.assertEquals('UPS', o.Carrier__c, 'carrier extracted');
        System.assertEquals('HELLO', o.Coupon_Code__c, 'coupon captured');
        System.assertEquals(1, [SELECT count() FROM OrderItem WHERE OrderId = :orderId], 'line item created');

        Lead l = [SELECT Purchase_Closed__c, Converted_Account__c FROM Lead WHERE Email = 'newbuyer@example.com' LIMIT 1];
        System.assertEquals(true, l.Purchase_Closed__c, 'lead lifecycle closed after purchase');
        System.assertEquals(a.Id, l.Converted_Account__c, 'lead linked to purchase account');
    }

    @isTest
    static void mapHelpers() {
        System.assertEquals('Shipped', WooOrderService.mapFulfillment('completed'), 'completed means fulfilled/shipped, not carrier-delivered');
        System.assertEquals('Processing', WooOrderService.mapFulfillment('processing'), 'processing');
        System.assertEquals(null, WooOrderService.mapFulfillment('weird'), 'unknown -> null');
        System.assertEquals('Paid', WooOrderService.mapPayment('processing', null), 'processing -> paid');
        System.assertEquals('Failed', WooOrderService.mapPayment('failed', null), 'failed');
    }
}
