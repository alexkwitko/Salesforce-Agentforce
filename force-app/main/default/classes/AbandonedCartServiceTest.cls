@isTest
private class AbandonedCartServiceTest {

    @isTest
    static void testNewShopperCreatesLead() {
        Cart__c cart = new Cart__c(Shopper_Email__c='new.shopper@example.com',
            Shopper_Name__c='Nina New', Cart_Value__c=42, Item_Count__c=2, Status__c='Active',
            Email_Consent__c=true);
        insert cart;

        Test.startTest();
        AbandonedCartService.Result r = AbandonedCartService.process(cart.Id);
        Test.stopTest();

        System.assertEquals(true, r.leadCreated, 'new shopper -> lead created');
        Lead l = [SELECT FirstName, LastName, Company, Email, Cart_Status__c, Last_Cart_Value__c, LeadSource, Email_Consent__c FROM Lead WHERE Id=:r.leadId];
        System.assertEquals('Nina', l.FirstName);
        System.assertEquals('New', l.LastName);
        System.assertEquals('Abandoned', l.Cart_Status__c);
        System.assertEquals(42, l.Last_Cart_Value__c);
        System.assertEquals(true, l.Email_Consent__c, 'cart consent carried onto lead');
        Cart__c c2 = [SELECT Lead__c, Status__c FROM Cart__c WHERE Id=:cart.Id];
        System.assertEquals(r.leadId, c2.Lead__c, 'cart linked to lead');
    }

    @isTest
    static void testKnownCustomerCreatesLeadLinkedToAccount() {
        Id paRt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account pa = new Account(FirstName='Reg', LastName='Customer',
            PersonEmail='reg.customer@example.com', RecordTypeId=paRt);
        insert pa;
        Cart__c cart = new Cart__c(Shopper_Email__c='reg.customer@example.com',
            Shopper_Name__c='Reg Customer', Cart_Value__c=80, Status__c='Active', Email_Consent__c=true);
        insert cart;

        Test.startTest();
        AbandonedCartService.Result r = AbandonedCartService.process(cart.Id);
        Test.stopTest();

        // BOTH known and unknown shoppers now get a Lead; known ones are linked to the Person Account.
        System.assertEquals(true, r.leadCreated, 'known customer -> lead IS created');
        System.assertNotEquals(null, r.leadId);
        Lead l = [SELECT Person_Account__c, Company, LeadSource FROM Lead WHERE Id=:r.leadId];
        System.assertEquals(pa.Id, l.Person_Account__c, 'lead related to the Person Account');
        System.assertEquals('Existing Customer', l.Company);
        Cart__c c2 = [SELECT Customer__c, Lead__c FROM Cart__c WHERE Id=:cart.Id];
        System.assertEquals(pa.Id, c2.Customer__c, 'cart linked to known customer');
        System.assertEquals(r.leadId, c2.Lead__c, 'cart also linked to the lead');
    }

    @isTest
    static void testExistingLeadKnownCustomerGetsAccountLink() {
        Id paRt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account pa = new Account(FirstName='Dup', LastName='Buyer', PersonEmail='dup.buyer@example.com', RecordTypeId=paRt);
        insert pa;
        insert new Lead(LastName='Buyer', Company='x', Email='dup.buyer@example.com', Status='Open - Not Contacted');
        Cart__c cart = new Cart__c(Shopper_Email__c='dup.buyer@example.com', Cart_Value__c=60, Status__c='Active');
        insert cart;

        Test.startTest();
        AbandonedCartService.Result r = AbandonedCartService.process(cart.Id);
        Test.stopTest();

        System.assertEquals(false, r.leadCreated, 'reuses existing lead');
        System.assertEquals(pa.Id, [SELECT Person_Account__c FROM Lead WHERE Id=:r.leadId].Person_Account__c,
            'existing lead now linked to the Person Account');
    }

    @isTest
    static void testExistingLeadUpdated() {
        Lead existing = new Lead(LastName='Old', Company='Online Shopper',
            Email='repeat@example.com', Status='Open - Not Contacted');
        insert existing;
        Cart__c cart = new Cart__c(Shopper_Email__c='repeat@example.com', Cart_Value__c=55, Status__c='Active');
        insert cart;

        Test.startTest();
        AbandonedCartService.Request req = new AbandonedCartService.Request();
        req.cartId = cart.Id;
        List<AbandonedCartService.Result> rs = AbandonedCartService.processAbandonedCart(
            new List<AbandonedCartService.Request>{ req });
        Test.stopTest();

        System.assertEquals(existing.Id, rs[0].leadId, 'reuses existing lead');
        System.assertEquals(false, rs[0].leadCreated);
        Lead l = [SELECT Cart_Status__c, Last_Cart_Value__c FROM Lead WHERE Id=:existing.Id];
        System.assertEquals('Abandoned', l.Cart_Status__c);
        System.assertEquals(55, l.Last_Cart_Value__c);
    }
}
