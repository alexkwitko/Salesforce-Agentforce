@isTest
private class ChatCommerceServicesTest {

    @isTest
    static void testChatLeadCaptureAndJourney() {
        ChatLeadService.Request r = new ChatLeadService.Request();
        r.email = 'chatlead@example.com'; r.firstName = 'Chatty'; r.lastName = 'Visitor';
        r.consent = true; r.interest = 'Espresso beans'; r.chatSummary = 'Asked about dark roasts';
        r.preferencesJson = '{"roast":"dark","brew":"espresso"}';

        Test.startTest();
        List<ChatLeadService.Result> res = ChatLeadService.capture(new List<ChatLeadService.Request>{ r });
        Test.stopTest();

        System.assertEquals(true, res[0].success);
        Lead l = [SELECT LeadSource, Email_Consent__c, Chat_Interest__c, Preferences__c FROM Lead WHERE Email = 'chatlead@example.com' LIMIT 1];
        System.assertEquals('Website Chat', l.LeadSource);
        System.assertEquals(true, l.Email_Consent__c);
        System.assertEquals(1, [SELECT count() FROM Customer_Journey__c WHERE Email__c = 'chatlead@example.com']);
    }

    @isTest
    static void testChatTranscriptLogsTaskOnKnownCustomerContact() {
        // a known customer (Person Account) chats -> transcript summary is logged as a Task on their Contact
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account a = new Account(RecordTypeId = rt, FirstName = 'Known', LastName = 'Buyer', PersonEmail = 'known.buyer@example.com');
        insert a;
        ChatLeadService.Request r = new ChatLeadService.Request();
        r.email = 'known.buyer@example.com'; r.firstName = 'Known'; r.chatSummary = 'Discussed a reorder of the dark roast.';
        Test.startTest();
        ChatLeadService.capture(new List<ChatLeadService.Request>{ r });
        Test.stopTest();
        Account acc = [SELECT PersonContactId FROM Account WHERE PersonEmail = 'known.buyer@example.com'];
        List<Task> tasks = [SELECT Subject, Description, Status FROM Task WHERE WhoId = :acc.PersonContactId AND Subject = 'Website chat'];
        System.assertEquals(1, tasks.size(), 'transcript task on the person contact');
        System.assertEquals('Completed', tasks[0].Status, 'logged as completed');
        System.assert(tasks[0].Description.contains('dark roast'), 'transcript summary captured on contact');
    }

    @isTest
    static void testCustomerLookupNewVsReturning() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='Reg', LastName='Ular', PersonEmail='returning@example.com', Customer_Status__c='Customer');
        insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=Test.getStandardPricebookId());
        insert o;

        Test.startTest();
        CustomerLookupService.Request rr = new CustomerLookupService.Request(); rr.email='returning@example.com';
        CustomerLookupService.Request rn = new CustomerLookupService.Request(); rn.email='nobody@example.com';
        List<CustomerLookupService.Result> res = CustomerLookupService.lookup(new List<CustomerLookupService.Request>{ rr, rn });
        Test.stopTest();

        System.assertEquals(true, res[0].isReturning, 'has order => returning');
        System.assertEquals('Customer', res[0].customerStatus);
        System.assertEquals(false, res[1].isReturning, 'unknown email => not returning');
    }

    @isTest
    static void testCustomerLookupWithholdsPrivateContextUntilVerified() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Id pb = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Private Bean', Family='Coffee', IsActive=true, Woo_Product_Id__c='12345');
        insert p;
        PricebookEntry pe = new PricebookEntry(Pricebook2Id=pb, Product2Id=p.Id, UnitPrice=24, IsActive=true);
        insert pe;

        Account a = new Account(RecordTypeId=rt, FirstName='Private', LastName='Buyer',
            PersonEmail='private.buyer@example.com', Customer_Status__c='Customer',
            Coffee_Preferences__c='{"roast":"dark","dislikes":["decaf"]}', Email_Consent__c=true,
            Data_Cloud_Segment__c='VIP', Data_Cloud_Churn_Risk__c='Low',
            Data_Cloud_Next_Best_Action__c='Offer a VIP perk.',
            Data_Cloud_Favorite_Category__c='Espresso',
            Data_Cloud_Profile_Summary__c='Segment VIP; risk Low; next action: Offer a VIP perk.');
        insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb);
        insert o;
        insert new OrderItem(OrderId=o.Id, Product2Id=p.Id, PricebookEntryId=pe.Id, Quantity=2, UnitPrice=24);
        insert new Cart__c(Shopper_Email__c='private.buyer@example.com', Status__c='Abandoned',
            Item_Count__c=2, Cart_Value__c=48);
        Customer_Journey__c j = new Customer_Journey__c(Name='private.buyer@example.com',
            Email__c='private.buyer@example.com', Coupon_Code__c='SAVEPRIVATE',
            Coupon_Redeemed__c=false, Coupon_Discount_Percent__c=15);
        insert j;
        insert new Agent_Interaction__c(Customer_Journey__c=j.Id, Agent__c='Growth',
            Action__c='issue_coupon', Result__c='Issued SAVEPRIVATE');
        insert new Case(AccountId=a.Id, Subject='Open delivery issue', Status='New', Origin='Web');

        CustomerLookupService.Request unverified = new CustomerLookupService.Request();
        unverified.email = 'private.buyer@example.com';
        CustomerLookupService.Request verified = new CustomerLookupService.Request();
        verified.email = 'private.buyer@example.com';
        verified.verifiedEmail = 'private.buyer@example.com';

        Test.startTest();
        List<CustomerLookupService.Result> res = CustomerLookupService.lookup(
            new List<CustomerLookupService.Request>{ unverified, verified });
        Test.stopTest();

        System.assertEquals(true, res[0].isReturning, 'unverified can be warmly recognized');
        System.assertEquals(0, res[0].orderCount, 'order count is withheld until sign-in');
        System.assertEquals(null, res[0].activeCouponCode, 'coupon is private until sign-in');
        System.assertEquals(null, res[0].savedCartSummary, 'cart is private until sign-in');
        System.assertEquals(null, res[0].dataCloudSegment, 'Data Cloud segment is private until sign-in');
        System.assert(!res[0].summary.contains('DATA CLOUD AUGMENTED CONTEXT'), 'augmented context withheld until sign-in');
        System.assert(res[0].summary.contains('IDENTITY NOT VERIFIED'), 'privacy warning included');
        System.assert(res[0].preferences.contains('decaf'), 'taste preferences can guide shopping help');

        System.assertEquals(1, res[1].orderCount, 'verified shopper gets order count');
        System.assertEquals(48, res[1].lifetimeValue, 'verified shopper gets LTV');
        System.assertEquals(true, res[1].hasSavedCart, 'verified shopper gets saved cart context');
        System.assertEquals('SAVEPRIVATE', res[1].activeCouponCode, 'verified shopper gets coupon context');
        System.assertEquals(1, res[1].openCaseCount, 'verified shopper gets case context');
        System.assert(res[1].lastAgentAction.contains('issue_coupon'), 'verified shopper gets last agent action');
        System.assertEquals('VIP', res[1].dataCloudSegment, 'verified shopper gets Data Cloud segment');
        System.assert(res[1].summary.contains('DATA CLOUD AUGMENTED CONTEXT'), 'verified shopper gets augmented context');
    }

    @isTest
    static void testEmailServiceConsentGate() {
        Lead l = new Lead(LastName='NoConsent', Company='C', Email='nc@example.com', Email_Consent__c=false);
        insert l;
        EmailService.Request req = new EmailService.Request();
        req.toEmail='nc@example.com'; req.subject='Hi'; req.htmlBody='<b>x</b>'; req.recordId=l.Id;

        Test.startTest();
        List<EmailService.Response> res = EmailService.send(new List<EmailService.Request>{ req });
        Test.stopTest();
        System.assertEquals(false, res[0].success, 'no consent => not sent');
    }

    @isTest
    static void testEmailServiceBlankRecordRequiresTransactionalFlag() {
        EmailService.Request marketing = new EmailService.Request();
        marketing.toEmail='shopper@example.com'; marketing.subject='Offer'; marketing.htmlBody='<b>x</b>';
        EmailService.Request transactional = new EmailService.Request();
        transactional.toEmail='shopper@example.com'; transactional.subject='Return label'; transactional.htmlBody='<b>x</b>';
        transactional.isTransactional = true;

        Test.startTest();
        List<EmailService.Response> res = EmailService.send(new List<EmailService.Request>{ marketing, transactional });
        Test.stopTest();
        System.assertEquals(false, res[0].success, 'blank record marketing send is blocked');
        System.assertEquals(true, res[1].success, 'explicit transactional send can bypass marketing consent');
    }

    @isTest
    static void testLeadLifecycleClose() {
        Lead cart = new Lead(LastName='Cart', Company='C', Email='buyer2@example.com', LeadSource='WooCommerce Abandoned Cart', Status='Working - Contacted');
        Lead chat = new Lead(LastName='Chat', Company='C', Email='buyer2@example.com', LeadSource='Website Chat', Status='Open - Not Contacted');
        insert new List<Lead>{ cart, chat };
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='B', LastName='Two', PersonEmail='buyer2@example.com');
        insert a;

        Test.startTest();
        LeadLifecycleService.closeForPurchase('buyer2@example.com', a.Id, null);
        Test.stopTest();

        List<Lead> closed = [SELECT Status, IsConverted, ConvertedAccountId, Purchase_Closed__c, Converted_Account__c FROM Lead WHERE Email='buyer2@example.com'];
        System.assertEquals(2, closed.size(), 'both source leads found');
        for (Lead l : closed) {
            System.assertEquals(true, l.Purchase_Closed__c);
            System.assertEquals(a.Id, l.Converted_Account__c);
            System.assertEquals(true, l.IsConverted, 'native Salesforce conversion should run after purchase');
            System.assertEquals(a.Id, l.ConvertedAccountId, 'native converted account should point at purchase account');
        }
    }

    @isTest
    static void testLeadLifecycleRetriesPreclosedUnconvertedLead() {
        Lead oldLead = new Lead(LastName='Old', Company='C', Email='oldbuyer@example.com',
            LeadSource='Website Chat', Status='Working - Contacted',
            Purchase_Closed__c=true, Closed_Date__c=System.now().addDays(-2));
        insert oldLead;
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='Old', LastName='Buyer', PersonEmail='oldbuyer@example.com');
        insert a;

        Test.startTest();
        LeadLifecycleService.closeForPurchase('oldbuyer@example.com', a.Id, null);
        Test.stopTest();

        Lead converted = [SELECT IsConverted, ConvertedAccountId, Purchase_Closed__c, Converted_Account__c
                          FROM Lead WHERE Id=:oldLead.Id];
        System.assertEquals(true, converted.Purchase_Closed__c);
        System.assertEquals(a.Id, converted.Converted_Account__c);
        System.assertEquals(true, converted.IsConverted, 'preclosed unconverted lead should retry native conversion');
        System.assertEquals(a.Id, converted.ConvertedAccountId);
    }

    @isTest
    static void testProductSuggestionGrounded() {
        Product2 p = new Product2(Name='Pop Bean', Family='Blends', IsActive=true, Stock_On_Hand__c=10, Woo_Product_Id__c='9999');
        insert p;
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rt, FirstName='S', LastName='B', PersonEmail='sb@example.com'); insert a;
        Id pb = Test.getStandardPricebookId();
        PricebookEntry pe = new PricebookEntry(Pricebook2Id=pb, Product2Id=p.Id, UnitPrice=15, IsActive=true); insert pe;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb); insert o;
        insert new OrderItem(OrderId=o.Id, Product2Id=p.Id, PricebookEntryId=pe.Id, Quantity=4, UnitPrice=15);

        Test.startTest();
        ProductSuggestionService.Request req = new ProductSuggestionService.Request(); req.howMany=3;
        List<ProductSuggestionService.Result> res = ProductSuggestionService.suggest(new List<ProductSuggestionService.Request>{ req });
        Test.stopTest();
        System.assert(res[0].count >= 1, 'returns at least the popular bean');
        System.assert(res[0].productNames.contains('Pop Bean'));
    }
}
