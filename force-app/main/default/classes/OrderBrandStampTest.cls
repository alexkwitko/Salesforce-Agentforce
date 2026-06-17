@isTest
private class OrderBrandStampTest {
    @isTest static void stampsByFamily() {
        Account a = new Account(Name='Brand Test'); insert a;
        Product2 bb = new Product2(Name='BB Machine', Family='Bean & Brew', IsActive=true); insert bb;
        Product2 kw = new Product2(Name='Kwitko Bag', Family='Single-Origin', IsActive=true); insert kw;
        Id pb = Test.getStandardPricebookId();
        PricebookEntry pbb = new PricebookEntry(Pricebook2Id=pb, Product2Id=bb.Id, UnitPrice=100, IsActive=true); insert pbb;
        PricebookEntry pkw = new PricebookEntry(Pricebook2Id=pb, Product2Id=kw.Id, UnitPrice=20, IsActive=true); insert pkw;
        Order ob = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb); insert ob;
        Order ok = new Order(AccountId=a.Id, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=pb); insert ok;
        Test.startTest();
        insert new OrderItem(OrderId=ob.Id, PricebookEntryId=pbb.Id, Quantity=1, UnitPrice=100);
        insert new OrderItem(OrderId=ok.Id, PricebookEntryId=pkw.Id, Quantity=1, UnitPrice=20);
        Test.stopTest();
        System.assertEquals('Bean & Brew', [SELECT Brand__c FROM Order WHERE Id=:ob.Id].Brand__c);
        System.assertEquals('Kwitko Coffee', [SELECT Brand__c FROM Order WHERE Id=:ok.Id].Brand__c);
    }
}
