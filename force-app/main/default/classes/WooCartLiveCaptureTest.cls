/**
 * Tests for live abandoned-cart capture: WooCartResource (upsert + HMAC POST) and
 * AbandonedCartSweep (1h inactivity -> Abandoned, or Converted if an order exists).
 */
@isTest
private class WooCartLiveCaptureTest {

    @testSetup
    static void setup() {
        insert new Woo_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Webhook_Secret__c = 'topsecret');
        insert new Product2(Name = 'Brazil Santos 12oz', Family = 'Single-Origin', IsActive = true,
            Stock_On_Hand__c = 50, Woo_Product_Id__c = '45');
    }

    private static Map<String, Object> payload(String email) {
        return new Map<String, Object>{
            'cart_id' => 'sess-abc-123', 'email' => email, 'first_name' => 'Cart', 'last_name' => 'Tester',
            'consent' => true, 'total' => 38.00,
            'items' => new List<Object>{
                new Map<String, Object>{ 'product_id' => 45, 'sku' => 'BEAN-BRZ', 'name' => 'Brazil Santos', 'quantity' => 2, 'price' => 19.0 } } };
    }

    @isTest
    static void testUpsertCreatesActiveCartWithItems() {
        Test.startTest();
        Id cartId = WooCartResource.upsertCart(payload('live.cart@example.com'));
        // second ping updates the same cart (idempotent on cart_id)
        WooCartResource.upsertCart(payload('live.cart@example.com'));
        Test.stopTest();
        Cart__c c = [SELECT Status__c, Shopper_Email__c, Cart_Value__c, Item_Count__c, Email_Consent__c FROM Cart__c WHERE Id = :cartId];
        System.assertEquals('Active', c.Status__c);
        System.assertEquals('live.cart@example.com', c.Shopper_Email__c);
        System.assertEquals(true, c.Email_Consent__c);
        System.assertEquals(2, c.Item_Count__c);
        Integer lines = [SELECT COUNT() FROM Cart_Item__c WHERE Cart__c = :cartId];
        System.assertEquals(1, lines, 'one line, replaced not duplicated on the second ping');
        Cart_Item__c li = [SELECT Product__c, Quantity__c, Line_Total__c FROM Cart_Item__c WHERE Cart__c = :cartId LIMIT 1];
        System.assertNotEquals(null, li.Product__c, 'resolved to Product2 by Woo id');
        System.assertEquals(38.00, li.Line_Total__c);
    }

    @isTest
    static void testCartValueUsesMerchandiseLinesNotInflatedPayloadTotal() {
        Map<String, Object> p = payload('line.total@example.com');
        p.put('total', 99.00);

        Id cartId = WooCartResource.upsertCart(p);

        Cart__c c = [SELECT Cart_Value__c FROM Cart__c WHERE Id = :cartId];
        System.assertEquals(38.00, c.Cart_Value__c,
            'abandoned-cart value should match reconstructed merchandise lines, not a Woo total that may include estimates');
    }

    @isTest
    static void testDuplicateCartRowsCollapseToOneCanonicalCart() {
        Cart__c staleA = new Cart__c(Woo_Cart_Id__c = 'sess-abc-123', Status__c = 'Active',
            Cart_Value__c = 1, Item_Count__c = 1);
        Cart__c staleB = new Cart__c(Woo_Cart_Id__c = 'sess-abc-123', Status__c = 'Active',
            Shopper_Email__c = 'canonical@example.com', Cart_Value__c = 2, Item_Count__c = 1);
        insert new List<Cart__c>{ staleA, staleB };
        insert new Cart_Item__c(Cart__c = staleA.Id, Quantity__c = 1, Unit_Price__c = 1, Line_Total__c = 1);
        insert new Cart_Item__c(Cart__c = staleB.Id, Quantity__c = 1, Unit_Price__c = 2, Line_Total__c = 2);

        Test.startTest();
        Id cartId = WooCartResource.upsertCart(payload('live.cart@example.com'));
        Test.stopTest();

        System.assertEquals(staleB.Id, cartId, 'cart with identity context is kept as canonical');
        System.assertEquals(1, [SELECT COUNT() FROM Cart__c WHERE Woo_Cart_Id__c = 'sess-abc-123'],
            'duplicate cart rows for one Woo token are collapsed');
        System.assertEquals(1, [SELECT COUNT() FROM Cart_Item__c WHERE Cart__c = :cartId],
            'canonical cart lines are replaced once');
        Cart__c kept = [SELECT Shopper_Email__c, Cart_Value__c, Item_Count__c FROM Cart__c WHERE Id = :cartId];
        System.assertEquals('live.cart@example.com', kept.Shopper_Email__c);
        System.assertEquals(38.00, kept.Cart_Value__c);
        System.assertEquals(2, kept.Item_Count__c);
    }

    @isTest
    static void testHmacPost() {
        String json = JSON.serialize(payload('hmac.cart@example.com'));
        Blob bodyBlob = Blob.valueOf(json);
        String sig = EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', bodyBlob, Blob.valueOf('topsecret')));
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/woo/cart/'; req.httpMethod = 'POST';
        req.requestBody = bodyBlob; req.headers.put('X-Kwitko-Signature', sig);
        RestContext.request = req; RestContext.response = new RestResponse();
        Test.startTest(); WooCartResource.handlePost(); Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        System.assertEquals(1, [SELECT COUNT() FROM Cart__c WHERE Shopper_Email__c = 'hmac.cart@example.com']);
    }

    @isTest
    static void testHmacRejectsBadSignature() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(JSON.serialize(payload('x@example.com')));
        req.headers.put('X-Kwitko-Signature', 'wrong');
        RestContext.request = req; RestContext.response = new RestResponse();
        Test.startTest(); WooCartResource.handlePost(); Test.stopTest();
        System.assertEquals(401, RestContext.response.statusCode);
    }

    @isTest
    static void testSweepMarksAbandoned() {
        Cart__c c = new Cart__c(Woo_Cart_Id__c = 'old-1', Status__c = 'Active',
            Shopper_Email__c = 'abandon.me@example.com', Shopper_Name__c = 'Aban Doner',
            Cart_Value__c = 25, Item_Count__c = 1, Email_Consent__c = true,
            Last_Activity__c = System.now().addHours(-2));
        insert c;
        Test.startTest(); Integer n = AbandonedCartSweep.run(); Test.stopTest();
        System.assert(n >= 1);
        System.assertEquals('Abandoned', [SELECT Status__c FROM Cart__c WHERE Id = :c.Id].Status__c);
        // the flow should have created an inside-sales lead
        System.assertEquals(1, [SELECT COUNT() FROM Lead WHERE Email = 'abandon.me@example.com' AND LeadSource = 'WooCommerce Abandoned Cart']);
    }

    @isTest
    static void testSweepMarksConvertedWhenOrderExists() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(RecordTypeId = rt, FirstName = 'Bought', LastName = 'Already', PersonEmail = 'bought@example.com');
        insert a;
        Id pb = Test.getStandardPricebookId();
        insert new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = pb);
        Cart__c c = new Cart__c(Woo_Cart_Id__c = 'old-2', Status__c = 'Active',
            Shopper_Email__c = 'bought@example.com', Cart_Value__c = 25, Item_Count__c = 1,
            Last_Activity__c = System.now().addHours(-2));
        insert c;
        Test.startTest(); AbandonedCartSweep.run(); Test.stopTest();
        System.assertEquals('Converted', [SELECT Status__c FROM Cart__c WHERE Id = :c.Id].Status__c);
    }
}
