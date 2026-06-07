@isTest
private class ConsentServiceTest {

    @isTest
    static void testLeadConsent() {
        Lead yes = new Lead(LastName='Yes', Company='Shop', Email='yes@example.com', Email_Consent__c=true);
        Lead no  = new Lead(LastName='No',  Company='Shop', Email='no@example.com',  Email_Consent__c=false);
        insert new List<Lead>{ yes, no };

        ConsentService.Request r1 = new ConsentService.Request(); r1.recordId = yes.Id;
        ConsentService.Request r2 = new ConsentService.Request(); r2.recordId = no.Id;
        Test.startTest();
        List<ConsentService.Result> res = ConsentService.check(new List<ConsentService.Request>{ r1, r2 });
        Test.stopTest();

        System.assertEquals(true,  res[0].hasConsent, 'consenting lead');
        System.assertEquals(false, res[1].hasConsent, 'non-consenting lead');
        System.assert(res[1].message.contains('STOP'), 'message warns to stop: ' + res[1].message);
    }

    @isTest
    static void testOrderAndAccountConsent() {
        Id paRt = [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=true LIMIT 1].Id;
        Account a = new Account(FirstName='Cons', LastName='Enting', PersonEmail='c@example.com',
            Email_Consent__c=true, RecordTypeId=paRt);
        insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft',
            Pricebook2Id=Test.getStandardPricebookId());
        insert o;

        Test.startTest();
        ConsentService.Result accRes = ConsentService.run(a.Id);
        ConsentService.Result ordRes = ConsentService.run(o.Id);
        ConsentService.Result nullRes = ConsentService.run(null);
        Test.stopTest();

        System.assertEquals(true, accRes.hasConsent, 'account consent');
        System.assertEquals(true, ordRes.hasConsent, 'order consent via account');
        System.assertEquals(false, nullRes.hasConsent, 'null id -> no consent');
    }
}
