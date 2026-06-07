/**
 * CoffeePersonalizationTest — covers the independent-axis recommendation filtering,
 * coffee attribute backfill, recommendation-conversion tracking, coupon redemption sync,
 * and coupon/recommendation efficiency analytics.
 */
@isTest
private class CoffeePersonalizationTest {

    private static Product2 coffee(String name, String fam, String bean, String brew, String roast, Boolean decaf, Boolean flav) {
        return new Product2(Name = name, Family = fam, IsActive = true, Stock_On_Hand__c = 50,
            Woo_Product_Id__c = String.valueOf(Math.abs((name).hashCode())),
            Bean_Type__c = bean, Brew_Style__c = brew, Roast_Level__c = roast,
            Is_Decaf__c = decaf, Is_Flavored__c = flav);
    }

    @testSetup
    static void setup() {
        List<Product2> ps = new List<Product2>{
            coffee('SO Light Regular', 'Single-Origin', 'Single-Origin', 'All-Purpose', 'Light', false, false),
            coffee('SO Dark Regular',  'Single-Origin', 'Single-Origin', 'All-Purpose', 'Dark',  false, false),
            coffee('Espresso Dark Blend', 'Espresso',   'Blend',         'Espresso',    'Dark',  false, false),
            coffee('Decaf SO Medium',  'Single-Origin', 'Single-Origin', 'All-Purpose', 'Medium', true, false),
            coffee('Vanilla Flavored', 'Flavored',      'Blend',         'All-Purpose', 'Medium', false, true),
            coffee('Hand Grinder',     'Grinders',      null,            null,          null,     false, false)
        };
        insert ps;
        Id stdPb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : ps) pbes.add(new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 18, IsActive = true));
        insert pbes;
    }

    @isTest
    static void testAxisHardFilters() {
        // single-origin + no decaf -> a single-origin, non-decaf coffee
        RecommendationStrategyService.Request r1 = new RecommendationStrategyService.Request();
        r1.email = 'axis1@example.com'; r1.channel = 'chat';
        r1.preferredBeanType = 'Single-Origin'; r1.wantsDecaf = false;

        // espresso brew -> the espresso product
        RecommendationStrategyService.Request r2 = new RecommendationStrategyService.Request();
        r2.email = 'axis2@example.com'; r2.channel = 'chat';
        r2.preferredBrewStyle = 'Espresso'; r2.wantsDecaf = false;

        // wants decaf -> the decaf product
        RecommendationStrategyService.Request r3 = new RecommendationStrategyService.Request();
        r3.email = 'axis3@example.com'; r3.channel = 'chat'; r3.wantsDecaf = true;

        Test.startTest();
        RecommendationStrategyService.Result a = RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ r1 })[0];
        RecommendationStrategyService.Result b = RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ r2 })[0];
        RecommendationStrategyService.Result c = RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ r3 })[0];
        Test.stopTest();

        System.assert(a.success, 'single-origin pick should succeed');
        Product2 ap = [SELECT Bean_Type__c, Is_Decaf__c FROM Product2 WHERE Id = :a.primaryProductId];
        System.assertEquals('Single-Origin', ap.Bean_Type__c, 'must honor bean type');
        System.assertEquals(false, ap.Is_Decaf__c, 'must not be decaf');

        Product2 bp = [SELECT Brew_Style__c FROM Product2 WHERE Id = :b.primaryProductId];
        System.assertEquals('Espresso', bp.Brew_Style__c, 'must honor espresso brew');

        Product2 cp = [SELECT Is_Decaf__c FROM Product2 WHERE Id = :c.primaryProductId];
        System.assertEquals(true, cp.Is_Decaf__c, 'must be decaf when requested');
    }

    @isTest
    static void testGracefulFallbackRelaxesBrewNotBean() {
        // single-origin + espresso is impossible in the catalog -> relax brew, keep bean type
        RecommendationStrategyService.Request r = new RecommendationStrategyService.Request();
        r.email = 'fallback@example.com'; r.channel = 'chat';
        r.preferredBeanType = 'Single-Origin'; r.preferredBrewStyle = 'Espresso'; r.wantsDecaf = false;

        Test.startTest();
        RecommendationStrategyService.Result res = RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ r })[0];
        Test.stopTest();

        System.assert(res.success, 'should still return a coffee via fallback');
        System.assert(res.relaxedAxesCsv != null && res.relaxedAxesCsv.contains('brew'), 'should relax brew style: ' + res.relaxedAxesCsv);
        Product2 p = [SELECT Bean_Type__c FROM Product2 WHERE Id = :res.primaryProductId];
        System.assertEquals('Single-Origin', p.Bean_Type__c, 'bean type must NOT be relaxed');
    }

    @isTest
    static void testConversionWriteback() {
        RecommendationStrategyService.Request r = new RecommendationStrategyService.Request();
        r.email = 'conv@example.com'; r.channel = 'chat'; r.preferredBeanType = 'Single-Origin';
        Test.startTest();
        RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ r });
        Test.stopTest();
        Customer_Journey__c j = [SELECT Recommended_Product_Ids__c FROM Customer_Journey__c WHERE Email__c = 'conv@example.com' LIMIT 1];
        System.assert(String.isNotBlank(j.Recommended_Product_Ids__c), 'recommended ids should be persisted for conversion tracking');
    }

    @isTest
    static void testBackfillDerivation() {
        CoffeeAttributeBackfill.Derived d = CoffeeAttributeBackfill.derive('Espresso', 'Decaf Espresso — Swiss Water 12oz');
        System.assertEquals(true, d.decaf, 'decaf detected by name');
        System.assertEquals('Espresso', d.brew, 'espresso brew');
        System.assertEquals('Dark', d.roast, 'espresso defaults dark');
        CoffeeAttributeBackfill.Derived s = CoffeeAttributeBackfill.derive('Single-Origin', 'Ethiopia Yirgacheffe — Light Roast 12oz');
        System.assertEquals('Single-Origin', s.beanType);
        System.assertEquals('Light', s.roast);
        Test.startTest();
        String msg = CoffeeAttributeBackfill.run();
        Test.stopTest();
        System.assert(msg.contains('Backfilled'), msg);
    }

    @isTest
    static void testPreferenceAxesCaptured() {
        Id personRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        insert new Account(RecordTypeId = personRt, FirstName = 'Pref', LastName = 'Axis', PersonEmail = 'pref@example.com');

        CustomerPreferenceService.Request r = new CustomerPreferenceService.Request();
        r.email = 'pref@example.com';
        r.beanType = 'single origin'; r.brew = 'espresso'; r.caffeine = 'no decaf'; r.flavored = 'avoid';

        Test.startTest();
        CustomerPreferenceService.Result res = CustomerPreferenceService.save(new List<CustomerPreferenceService.Request>{ r })[0];
        Test.stopTest();

        System.assert(res.success);
        System.assert(res.preferencesJson.contains('single-origin'), 'beanType stored: ' + res.preferencesJson);
        System.assert(res.preferencesJson.contains('"caffeine":"regular"'), 'caffeine normalized: ' + res.preferencesJson);
        System.assert(res.preferencesJson.contains('decaf'), 'regular should add decaf to dislikes for keyword filter');
        System.assert(res.preferencesJson.contains('"flavored":"avoid"'), 'flavored avoid stored');
    }

    @isTest
    static void testCouponRedemptionSyncAndAnalytics() {
        // a journey with an issued (unredeemed) coupon
        Customer_Journey__c j = new Customer_Journey__c(Name = 'buyer@example.com', Email__c = 'buyer@example.com',
            Coupon_Code__c = 'KW-TEST-10-9999', Coupon_Issued_Date__c = System.now(),
            Coupon_Discount_Percent__c = 10, Coupon_Redeemed__c = false);
        insert j;

        // an abandoned cart + its recovery lead for this shopper -> should become Recovered on redemption
        Lead recLead = new Lead(FirstName = 'Buy', LastName = 'Er', Company = 'Web',
            Email = 'buyer@example.com', Cart_Status__c = 'Abandoned', LeadSource = 'Abandoned Cart');
        insert recLead;
        Cart__c abandoned = new Cart__c(Shopper_Email__c = 'buyer@example.com', Cart_Value__c = 36,
            Status__c = 'Abandoned', Lead__c = recLead.Id);
        insert abandoned;

        Product2 p = [SELECT Id, Woo_Product_Id__c FROM Product2 WHERE Name = 'SO Light Regular' LIMIT 1];

        Map<String, Object> order = new Map<String, Object>{
            'id' => 778899,
            'billing' => new Map<String, Object>{ 'email' => 'buyer@example.com', 'first_name' => 'Buy', 'last_name' => 'Er' },
            'discount_total' => '3.60',
            'coupon_lines' => new List<Object>{ new Map<String, Object>{ 'code' => 'KW-TEST-10-9999' } },
            'line_items' => new List<Object>{ new Map<String, Object>{ 'product_id' => p.Woo_Product_Id__c, 'quantity' => 1, 'price' => '18' } }
        };

        Test.startTest();
        WooOrderService.ingestOrder(order);
        CouponAnalyticsService.Metrics m = CouponAnalyticsService.getMetrics(new List<String>{ 'x' })[0];
        Test.stopTest();

        Customer_Journey__c after = [SELECT Coupon_Redeemed__c, Coupon_Discount_Amount__c, Coupon_Redeemed_Order_Id__c
                                     FROM Customer_Journey__c WHERE Email__c = 'buyer@example.com' LIMIT 1];
        System.assertEquals(true, after.Coupon_Redeemed__c, 'coupon should be marked redeemed');
        System.assertEquals(3.60, after.Coupon_Discount_Amount__c, 'discount captured');
        System.assertEquals('778899', after.Coupon_Redeemed_Order_Id__c, 'redeemed order captured');
        System.assert(m.couponsIssued >= 1 && m.couponsRedeemed >= 1, 'analytics counts issued/redeemed');
        System.assert(m.redemptionRatePct > 0, 'redemption rate computed');

        // redeeming an issued coupon marks the abandoned cart + its lead Recovered (C4 lifecycle)
        Cart__c recCart = [SELECT Status__c FROM Cart__c WHERE Id = :abandoned.Id];
        System.assertEquals('Recovered', recCart.Status__c, 'cart recovered via redeemed coupon');
        Lead afterLead = [SELECT Cart_Status__c FROM Lead WHERE Id = :recLead.Id];
        System.assertEquals('Recovered', afterLead.Cart_Status__c, 'lead cart-status recovered');
    }

    @isTest
    static void testAddRecommendedHelper() {
        Test.startTest();
        JourneyService.addRecommended('rec@example.com', '01t000000000001AAA,01t000000000002AAA');
        JourneyService.addRecommended('rec@example.com', '01t000000000002AAA,01t000000000003AAA');
        Test.stopTest();
        Customer_Journey__c j = [SELECT Recommended_Product_Ids__c FROM Customer_Journey__c WHERE Email__c = 'rec@example.com' LIMIT 1];
        System.assert(j.Recommended_Product_Ids__c.contains('01t000000000003AAA'), 'merges new ids');
    }
}
