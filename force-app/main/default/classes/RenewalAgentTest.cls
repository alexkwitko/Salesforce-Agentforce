@isTest
private class RenewalAgentTest {
    @TestSetup
    static void setup() {
        Product2 p = new Product2(Name = 'Coffee Club Subscription', ProductCode = 'COFFEE-CLUB', IsActive = true, Family = 'Subscription');
        insert p;
        Account a1 = new Account(Name = 'Acme Test', Churn_Risk_Tier__c = 'A', Churn_Score__c = 0.8);
        Account a2 = new Account(Name = 'Bluebird Test', Churn_Risk_Tier__c = 'C', Churn_Score__c = 0.1);
        insert new List<Account>{ a1, a2 };
        Date t = Date.today();
        insert new List<Asset>{
            new Asset(Name = 'Coffee Club Subscription', AccountId = a1.Id, Product2Id = p.Id, Quantity = 10, Price = 180,
                Status = 'Installed', InstallDate = t, UsageEndDate = t.addDays(20)),
            new Asset(Name = 'Coffee Club Subscription', AccountId = a2.Id, Product2Id = p.Id, Quantity = 30, Price = 180,
                Status = 'Installed', InstallDate = t, UsageEndDate = t.addDays(15))
        };
    }

    @isTest
    static void bookRenewLogAndSchedule() {
        Test.startTest();
        RenewalGetBook.Response b = RenewalGetBook.run(new List<RenewalGetBook.Request>{ new RenewalGetBook.Request() })[0];
        System.assert(b.count >= 2, 'book should list due subs');

        RenewalRenew.Request rr = new RenewalRenew.Request(); rr.accountName = 'Acme Test'; rr.termMonths = 12;
        System.assert(RenewalRenew.run(new List<RenewalRenew.Request>{ rr })[0].success, 'renew');

        RenewalLogPlay.Request lr = new RenewalLogPlay.Request();
        lr.accountName = 'Bluebird Test'; lr.playType = 'Upsell'; lr.note = 'test note';
        System.assert(RenewalLogPlay.run(new List<RenewalLogPlay.Request>{ lr })[0].success, 'logPlay');

        Integer created = RenewalRetentionScheduler.sweep(30);
        System.assert(created >= 1, 'sweep should create at least one worklist task');

        // cover the Schedulable execute() path
        System.schedule('Renewal Test Sweep', '0 0 7 * * ?', new RenewalRetentionScheduler());
        Test.stopTest();
    }

    @isTest
    static void notFoundPaths() {
        RenewalRenew.Request rr = new RenewalRenew.Request(); rr.accountName = 'No Such Co';
        System.assertEquals(false, RenewalRenew.run(new List<RenewalRenew.Request>{ rr })[0].success);
        RenewalLogPlay.Request lr = new RenewalLogPlay.Request(); lr.accountName = 'No Such Co'; lr.playType = 'X';
        System.assertEquals(false, RenewalLogPlay.run(new List<RenewalLogPlay.Request>{ lr })[0].success);
    }
}
