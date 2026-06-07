@isTest
private class AgentContextServiceTest {
    @isTest
    static void sharedContextRespectsVerifiedIdentityAndHandoff() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Id pb = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Context Bean', Family='Espresso', IsActive=true, Stock_On_Hand__c=20, Woo_Product_Id__c='81001');
        insert p;
        PricebookEntry pe = new PricebookEntry(Pricebook2Id=pb, Product2Id=p.Id, UnitPrice=24, IsActive=true);
        insert pe;

        Account a = new Account(RecordTypeId=rt, FirstName='Shared', LastName='Context',
            PersonEmail='shared.context@example.com', Customer_Status__c='Customer',
            Coffee_Preferences__c='{"roast":"medium","dislikes":["decaf"]}', Email_Consent__c=true,
            Data_Cloud_Segment__c='VIP', Data_Cloud_Churn_Risk__c='Low',
            Data_Cloud_Next_Best_Action__c='Offer a VIP perk.',
            Data_Cloud_Favorite_Category__c='Espresso');
        insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb);
        insert o;
        insert new OrderItem(OrderId=o.Id, Product2Id=p.Id, PricebookEntryId=pe.Id, Quantity=2, UnitPrice=24);
        insert new Cart__c(Shopper_Email__c='shared.context@example.com', Status__c='Abandoned',
            Item_Count__c=2, Cart_Value__c=48);
        Customer_Journey__c j = new Customer_Journey__c(Name='shared.context@example.com',
            Email__c='shared.context@example.com', Coupon_Code__c='SAVEPRIVATE',
            Coupon_Redeemed__c=false, Coupon_Discount_Percent__c=15,
            Last_Agent__c='Post_Purchase_Growth', Last_Stage__c='Offer');
        insert j;
        insert new Agent_Interaction__c(Customer_Journey__c=j.Id, Agent__c='Post_Purchase_Growth',
            Action__c='generate_offer', Result__c='Issued SAVEPRIVATE');
        insert new Case(AccountId=a.Id, Subject='Open delivery issue', Status='New', Origin='Web');

        AgentContextService.Request unverified = new AgentContextService.Request();
        unverified.email = 'shared.context@example.com';
        unverified.agentName = 'Kwitko_Concierge_Web';
        unverified.intent = 'where is my order';

        AgentContextService.Request verified = new AgentContextService.Request();
        verified.email = 'shared.context@example.com';
        verified.verifiedEmail = 'shared.context@example.com';
        verified.agentName = 'Kwitko_Concierge_Web';
        verified.intent = 'where is my order';

        Test.startTest();
        List<AgentContextService.Result> res = AgentContextService.getContext(
            new List<AgentContextService.Request>{ unverified, verified });
        Test.stopTest();

        System.assertEquals(true, res[0].success);
        System.assertEquals(false, res[0].identityVerified);
        System.assertEquals(true, res[0].mustAskForSignIn);
        System.assertEquals('Service', res[0].handoffTarget);
        System.assertEquals(null, res[0].activeCouponCode, 'coupon withheld until sign-in');
        System.assertEquals(null, res[0].savedCartSummary, 'cart withheld until sign-in');
        System.assertEquals(null, res[0].dataCloudSegment, 'Data Cloud segment withheld until sign-in');
        System.assert(res[0].summary.contains('PRIVATE CONTEXT WITHHELD'), 'privacy line is explicit');
        System.assert(!res[0].contextJson.contains('SAVEPRIVATE'), 'private coupon not leaked into context JSON');
        System.assert(res[0].preferences.contains('decaf'), 'taste preferences remain usable for shopping');

        System.assertEquals(true, res[1].identityVerified);
        System.assertEquals(false, res[1].mustAskForSignIn);
        System.assertEquals('verified_shopper', res[1].privacyMode);
        System.assertEquals('SAVEPRIVATE', res[1].activeCouponCode);
        System.assertEquals(true, res[1].hasSavedCart);
        System.assertEquals(1, res[1].openCaseCount);
        System.assertEquals('VIP', res[1].dataCloudSegment);
        System.assertEquals('Post_Purchase_Growth', res[1].lastAgent);
        System.assert(res[1].contextJson.contains('SAVEPRIVATE'), 'verified context carries private handoff facts');
    }

    @isTest
    static void trustedEmployeeRecordCanResolveLeadContextButWebCannotEscalateIt() {
        Lead l = new Lead(LastName='Cart', Company='Kwitko', Email='lead.context@example.com',
            LeadSource='WooCommerce Abandoned Cart', Status='Open - Not Contacted');
        insert l;
        insert new Cart__c(Shopper_Email__c='lead.context@example.com', Status__c='Abandoned',
            Item_Count__c=1, Cart_Value__c=19);
        Customer_Journey__c j = new Customer_Journey__c(Name='lead.context@example.com',
            Email__c='lead.context@example.com', Coupon_Code__c='LEADPRIVATE',
            Coupon_Redeemed__c=false, Coupon_Discount_Percent__c=20);
        insert j;

        AgentContextService.Request internalReq = new AgentContextService.Request();
        internalReq.recordId = l.Id;
        internalReq.recordScopedContext = true;
        internalReq.agentName = 'Inside_Sales';
        internalReq.intent = 'cart recovery';

        AgentContextService.Request webReq = new AgentContextService.Request();
        webReq.recordId = l.Id;
        webReq.recordScopedContext = true;
        webReq.agentName = 'Kwitko_Concierge_Web';
        webReq.intent = 'cart recovery';

        AgentContextService.Request minimalEmployeeReq = new AgentContextService.Request();
        minimalEmployeeReq.recordId = l.Id;

        Test.startTest();
        List<AgentContextService.Result> res = AgentContextService.getContext(
            new List<AgentContextService.Request>{ internalReq, webReq, minimalEmployeeReq });
        Test.stopTest();

        System.assertEquals(true, res[0].identityVerified, 'trusted employee record context is allowed');
        System.assertEquals('trusted_internal_record', res[0].privacyMode);
        System.assertEquals('lead.context@example.com', res[0].email);
        System.assertEquals('LEADPRIVATE', res[0].activeCouponCode);
        System.assertEquals('Inside_Sales', res[0].handoffTarget);

        System.assertEquals(false, res[1].identityVerified, 'web agent cannot escalate record-scoped trust');
        System.assertEquals(null, res[1].activeCouponCode);
        System.assert(!res[1].contextJson.contains('LEADPRIVATE'), 'web path does not leak lead coupon');

        System.assertEquals(true, res[2].identityVerified, 'employee agent can recover when only recordId is passed');
        System.assertEquals('trusted_internal_record', res[2].privacyMode);
        System.assertEquals('lead.context@example.com', res[2].email);
        System.assertEquals('LEADPRIVATE', res[2].activeCouponCode);
        System.assertEquals('Inside_Sales', res[2].handoffTarget);
    }
}
