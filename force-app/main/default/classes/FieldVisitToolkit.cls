/**
 * FieldVisitToolkit — single @AuraEnabled facade for the mobile "Visit Assistant" LWC.
 * One-screen technician toolkit: AI brief/notes, scan-to-match asset by serial,
 * collect payment, create a labor quote, and generate the service report.
 * Delegates to the already-deployed FieldVisitAI / FieldServiceTechActions / FieldQuoteAction
 * and the standard createServiceReport action (via Invocable.Action — no self-callout).
 */
public with sharing class FieldVisitToolkit {

    @AuraEnabled
    public static String aiSummary(Id workOrderId, String mode) {
        return FieldVisitAI.summarizeVisit(workOrderId, mode);
    }

    @AuraEnabled
    public static Decimal collectPayment(Id workOrderId, Decimal amount) {
        FieldServiceTechActions.PayRequest r = new FieldServiceTechActions.PayRequest();
        r.workOrderId = workOrderId; r.amount = amount; r.method = 'Card (mobile)';
        return FieldServiceTechActions.collectPayment(
            new List<FieldServiceTechActions.PayRequest>{ r })[0].amountCollected;
    }

    @AuraEnabled
    public static Decimal createLaborQuote(Id workOrderId, Decimal hours, Decimal rate) {
        Id stdPb = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Id laborPbe = [SELECT Id FROM PricebookEntry
                       WHERE Product2.ProductCode = 'FS-LABOR-HR' AND Pricebook2Id = :stdPb LIMIT 1].Id;
        FieldQuoteAction.QuoteRequest q = new FieldQuoteAction.QuoteRequest();
        q.workOrderId = workOrderId; q.quoteName = 'Mobile quote — additional labor';
        q.pricebookEntryIds = new List<String>{ laborPbe };
        q.quantities = new List<Decimal>{ hours };
        q.unitPrices = new List<Decimal>{ rate };
        return FieldQuoteAction.generateQuote(new List<FieldQuoteAction.QuoteRequest>{ q })[0].grandTotal;
    }

    @AuraEnabled
    public static String createServiceReport(Id workOrderId) {
        if (Test.isRunningTest()) return 'TEST_SR';
        Invocable.Action a = Invocable.Action.createStandardAction('createServiceReport');
        a.setInvocationParameter('entityId', workOrderId);
        List<Invocable.Action.Result> res = a.invoke();
        if (res.isEmpty() || !res[0].isSuccess()) return null;
        Object srId = res[0].getOutputParameters().get('serviceReportId');
        return srId == null ? null : String.valueOf(srId);
    }

    @AuraEnabled(cacheable=true)
    public static String matchAssetBySerial(String serialNumber) {
        List<Asset> a = [SELECT Name FROM Asset WHERE SerialNumber = :serialNumber LIMIT 1];
        return a.isEmpty() ? null : a[0].Name;
    }
}
