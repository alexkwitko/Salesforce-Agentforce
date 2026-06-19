@isTest
private class BrandAffinityServiceTest {
    @isTest static void rollsUpMultiBrand() {
        Account a = new Account(Name='Cross Brand Buyer'); insert a;
        Id pb = Test.getStandardPricebookId();
        Order o1 = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb);
        Order o2 = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb);
        insert new List<Order>{o1, o2};
        o1.Brand__c='Kwitko Coffee'; o2.Brand__c='Bean & Brew';
        update new List<Order>{o1, o2};
        Test.startTest();
        Integer n = BrandAffinityService.run();
        Test.stopTest();
        System.assert(n >= 1, 'at least one account rolled up');
        Account chk = [SELECT Brands_Purchased__c, Is_Multi_Brand__c FROM Account WHERE Id=:a.Id];
        System.assertEquals(true, chk.Is_Multi_Brand__c, 'two brands -> multi-brand');
        System.assert(chk.Brands_Purchased__c.contains('Bean & Brew') && chk.Brands_Purchased__c.contains('Kwitko Coffee'),
            'both brands listed: ' + chk.Brands_Purchased__c);
    }
    @isTest static void singleBrandNotMulti() {
        Account a = new Account(Name='Coffee Only'); insert a;
        Order o = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=Test.getStandardPricebookId());
        insert o; o.Brand__c='Kwitko Coffee'; update o;
        Test.startTest(); BrandAffinityService.run(); Test.stopTest();
        Account chk = [SELECT Brands_Purchased__c, Is_Multi_Brand__c FROM Account WHERE Id=:a.Id];
        System.assertEquals(false, chk.Is_Multi_Brand__c, 'one brand -> not multi');
        System.assertEquals('Kwitko Coffee', chk.Brands_Purchased__c);
    }
}
