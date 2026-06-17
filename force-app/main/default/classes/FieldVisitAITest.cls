@isTest
private class FieldVisitAITest {
    @isTest static void testBriefAndNotes() {
        Account a = new Account(Name='AI Test Acct'); insert a;
        WorkOrder wo = new WorkOrder(AccountId=a.Id, Subject='Quarterly maintenance'); insert wo;
        Test.startTest();
        System.assertEquals('TEST_SUMMARY', FieldVisitAI.summarizeVisit(wo.Id, 'brief'));
        FieldVisitAI.Req r = new FieldVisitAI.Req(); r.workOrderId=wo.Id; r.mode='notes';
        List<FieldVisitAI.Res> res = FieldVisitAI.generate(new List<FieldVisitAI.Req>{ r });
        Test.stopTest();
        System.assertEquals('TEST_SUMMARY', res[0].summary);
    }
}
