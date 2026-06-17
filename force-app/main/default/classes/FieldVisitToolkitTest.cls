@isTest
private class FieldVisitToolkitTest {
    @isTest static void testToolkit() {
        Account ac = new Account(Name='TK Acct'); insert ac;
        WorkOrder wo = new WorkOrder(AccountId=ac.Id, Subject='TK visit'); insert wo;
        Id stdPb = Test.getStandardPricebookId();
        Product2 p = new Product2(Name='Field Repair Labor (hr)', ProductCode='FS-LABOR-HR', IsActive=true); insert p;
        insert new PricebookEntry(Pricebook2Id=stdPb, Product2Id=p.Id, UnitPrice=95, IsActive=true);
        Asset asn = new Asset(Name='TK Asset', AccountId=ac.Id, SerialNumber='TK-SN-1'); insert asn;

        Test.startTest();
        System.assertEquals('TEST_SUMMARY', FieldVisitToolkit.aiSummary(wo.Id, 'brief'));
        System.assertEquals(150.00, FieldVisitToolkit.collectPayment(wo.Id, 150));
        System.assertEquals(190.00, FieldVisitToolkit.createLaborQuote(wo.Id, 2, 95));
        System.assertEquals('TEST_SR', FieldVisitToolkit.createServiceReport(wo.Id));
        System.assertEquals('TK Asset', FieldVisitToolkit.matchAssetBySerial('TK-SN-1'));
        Test.stopTest();
    }
}
