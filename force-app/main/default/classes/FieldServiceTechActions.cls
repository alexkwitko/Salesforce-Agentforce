/**
 * FieldServiceTechActions — Collect Field Payment
 * Invocable Action (Flow / mobile quick action on Work Order): records a customer
 * payment for a Work Order through the org's payment gateway and marks the Work Order
 * paid. ProcessingMode='External' records the collected amount (live card capture
 * routes through Pay Now / a partner reader; card data is never keyed into Salesforce).
 * Quote generation lives in FieldQuoteAction (one @InvocableMethod per class).
 */
public with sharing class FieldServiceTechActions {

    public class PayRequest {
        @InvocableVariable(required=true label='Work Order Id') public Id workOrderId;
        @InvocableVariable(label='Amount (defaults to Work Order Grand Total)') public Decimal amount;
        @InvocableVariable(label='Method e.g. Card/Cash') public String method;
    }
    public class PayResult {
        @InvocableVariable public Id paymentId;
        @InvocableVariable public Decimal amountCollected;
        @InvocableVariable public String status;
    }

    @InvocableMethod(label='Collect Field Payment'
        description='Records a customer payment for a work order via the org payment gateway and marks the work order paid.')
    public static List<PayResult> collectPayment(List<PayRequest> reqs) {
        List<PayResult> out = new List<PayResult>();
        Id gatewayId;
        List<PaymentGateway> pgs = [SELECT Id FROM PaymentGateway WHERE Status='Active' ORDER BY CreatedDate LIMIT 1];
        if (!pgs.isEmpty()) gatewayId = pgs[0].Id;

        for (PayRequest r : reqs) {
            WorkOrder wo = [SELECT Id, WorkOrderNumber, AccountId, GrandTotal FROM WorkOrder WHERE Id = :r.workOrderId];
            Decimal amt = (r.amount != null) ? r.amount : wo.GrandTotal;
            PayResult pr = new PayResult();
            if (amt == null || amt <= 0) { pr.status = 'No amount to charge'; out.add(pr); continue; }

            PaymentGroup pg = new PaymentGroup();
            insert pg;
            Payment p = new Payment(
                PaymentGroupId   = pg.Id,
                AccountId        = wo.AccountId,
                Amount           = amt,
                Type             = 'Sale',
                Status           = 'Processed',
                ProcessingMode   = 'External',
                PaymentGatewayId = gatewayId,
                EffectiveDate    = System.now(),
                Comments         = 'Field-collected for Work Order ' + wo.WorkOrderNumber
                                   + (r.method != null ? ' (' + r.method + ')' : ''));
            insert p;

            wo.Payment_Status__c   = 'Paid';
            wo.Amount_Collected__c = amt;
            update wo;

            pr.paymentId = p.Id; pr.amountCollected = amt; pr.status = 'Processed';
            out.add(pr);
        }
        return out;
    }
}
