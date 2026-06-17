/**
 * FieldQuoteAction — Generate Field Quote
 * Invocable Action (Flow / mobile quick action on Work Order): a technician generates a
 * customer Quote for additional / out-of-scope work found on the visit. Creates the
 * required Opportunity + Quote + QuoteLineItems on the standard price book and returns
 * the quote's GrandTotal so the tech can present/send it (and, once approved, collect
 * payment via FieldServiceTechActions.collectPayment).
 */
public with sharing class FieldQuoteAction {

    public class QuoteRequest {
        @InvocableVariable(required=true label='Work Order Id') public Id workOrderId;
        @InvocableVariable(label='Quote Name') public String quoteName;
        @InvocableVariable(required=true label='Pricebook Entry Ids') public List<String> pricebookEntryIds;
        @InvocableVariable(required=true label='Quantities') public List<Decimal> quantities;
        @InvocableVariable(label='Unit Price overrides (optional)') public List<Decimal> unitPrices;
    }
    public class QuoteResult {
        @InvocableVariable public Id quoteId;
        @InvocableVariable public Id opportunityId;
        @InvocableVariable public Decimal grandTotal;
    }

    @InvocableMethod(label='Generate Field Quote'
        description='Creates a customer quote (Opportunity + Quote + line items) for additional work from a work order.')
    public static List<QuoteResult> generateQuote(List<QuoteRequest> reqs) {
        List<QuoteResult> out = new List<QuoteResult>();
        Id stdPb = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        List<OpportunityStage> stages = [SELECT MasterLabel FROM OpportunityStage
                            WHERE IsActive = true AND IsClosed = false ORDER BY SortOrder LIMIT 1];
        String openStage = stages.isEmpty() ? 'Prospecting' : stages[0].MasterLabel;

        for (QuoteRequest r : reqs) {
            WorkOrder wo = [SELECT Id, WorkOrderNumber, AccountId FROM WorkOrder WHERE Id = :r.workOrderId];
            String nm = (r.quoteName != null) ? r.quoteName : 'Field Quote — WO ' + wo.WorkOrderNumber;

            Opportunity opp = new Opportunity(Name = nm, AccountId = wo.AccountId,
                StageName = openStage, CloseDate = Date.today().addDays(30), Pricebook2Id = stdPb);
            insert opp;

            Quote q = new Quote(Name = nm, OpportunityId = opp.Id, Pricebook2Id = stdPb,
                Status = 'Draft', ExpirationDate = Date.today().addDays(30));
            insert q;

            Map<Id, Decimal> pbePrice = new Map<Id, Decimal>();
            for (PricebookEntry pe : [SELECT Id, UnitPrice FROM PricebookEntry WHERE Id IN :r.pricebookEntryIds]) {
                pbePrice.put(pe.Id, pe.UnitPrice);
            }
            List<QuoteLineItem> qlis = new List<QuoteLineItem>();
            for (Integer i = 0; i < r.pricebookEntryIds.size(); i++) {
                Id pbeId = (Id) r.pricebookEntryIds[i];
                Decimal up = (r.unitPrices != null && r.unitPrices.size() > i && r.unitPrices[i] != null)
                             ? r.unitPrices[i] : pbePrice.get(pbeId);
                qlis.add(new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbeId,
                    Quantity = r.quantities[i], UnitPrice = up));
            }
            insert qlis;

            QuoteResult qr = new QuoteResult();
            qr.quoteId = q.Id; qr.opportunityId = opp.Id;
            qr.grandTotal = [SELECT GrandTotal FROM Quote WHERE Id = :q.Id].GrandTotal;
            out.add(qr);
        }
        return out;
    }
}
