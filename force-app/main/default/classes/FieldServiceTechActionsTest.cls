@isTest
private class FieldServiceTechActionsTest {

    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'FSTA Test Acct');
        insert a;
        WorkOrder wo = new WorkOrder(AccountId = a.Id, Subject = 'FSTA WO');
        insert wo;

        Product2 p = new Product2(Name = 'FSTA Labor', IsActive = true);
        insert p;
        Id stdPb = Test.getStandardPricebookId();
        insert new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 95, IsActive = true);
    }

    @isTest
    static void testCollectPayment() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        FieldServiceTechActions.PayRequest r = new FieldServiceTechActions.PayRequest();
        r.workOrderId = wo.Id; r.amount = 206.00; r.method = 'Card';

        Test.startTest();
        List<FieldServiceTechActions.PayResult> res =
            FieldServiceTechActions.collectPayment(new List<FieldServiceTechActions.PayRequest>{ r });
        Test.stopTest();

        System.assertEquals('Processed', res[0].status);
        System.assertEquals(206.00, res[0].amountCollected);
        WorkOrder check = [SELECT Payment_Status__c, Amount_Collected__c, AccountId FROM WorkOrder WHERE Id = :wo.Id];
        System.assertEquals('Paid', check.Payment_Status__c);
        System.assertEquals(206.00, check.Amount_Collected__c);
        System.assertEquals(1, [SELECT COUNT() FROM Payment WHERE AccountId = :check.AccountId]);
    }

    @isTest
    static void testCollectPaymentNoAmount() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        FieldServiceTechActions.PayRequest r = new FieldServiceTechActions.PayRequest();
        r.workOrderId = wo.Id; // no amount, WO GrandTotal null
        Test.startTest();
        List<FieldServiceTechActions.PayResult> res =
            FieldServiceTechActions.collectPayment(new List<FieldServiceTechActions.PayRequest>{ r });
        Test.stopTest();
        System.assertEquals('No amount to charge', res[0].status);
    }

    @isTest
    static void testGenerateQuote() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
        FieldQuoteAction.QuoteRequest r = new FieldQuoteAction.QuoteRequest();
        r.workOrderId = wo.Id;
        r.quoteName = 'Test Quote';
        r.pricebookEntryIds = new List<String>{ pbe.Id };
        r.quantities = new List<Decimal>{ 2 };
        r.unitPrices = new List<Decimal>{ 95 };

        Test.startTest();
        List<FieldQuoteAction.QuoteResult> res =
            FieldQuoteAction.generateQuote(new List<FieldQuoteAction.QuoteRequest>{ r });
        Test.stopTest();

        System.assertNotEquals(null, res[0].quoteId);
        System.assertEquals(1, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :res[0].quoteId]);
        System.assertEquals(190.00, res[0].grandTotal);
    }
}
