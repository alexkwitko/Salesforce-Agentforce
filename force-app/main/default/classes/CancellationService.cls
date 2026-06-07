/**
 * CancellationService — agent action to cancel an order that hasn't shipped yet: eligibility check,
 * WooCommerce cancel + refund (real money per build decision), Order.Fulfillment_Status__c='Cancelled',
 * and a tracking Case. Idempotent.
 */
public without sharing class CancellationService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Order Identifier (Woo id / order number, optional — defaults to latest)') public String orderIdentifier;
        @InvocableVariable(label='Cancellation Reason') public String reason;
        @InvocableVariable(label='Verified Email (pass loggedInEmail — required to cancel)') public String verifiedEmail;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms this cancellation/refund.') public Boolean confirmed;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String orderNumber;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public Boolean refundIssued;
        @InvocableVariable public Decimal refundAmount;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Cancel Order'
        description='Cancels an order that has not shipped: checks eligibility, cancels + refunds in WooCommerce, updates Salesforce, and opens a case. Blocks cancellation once shipped.')
    public static List<Result> cancel(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doCancel(r));
        return out;
    }

    private static Result doCancel(Request r) {
        Result res = new Result(); res.success = false;
        // IDENTITY GATE: cancelling an order is a destructive, account-scoped action — verified only.
        if (!IdentityService.isVerified(r.email, r.verifiedEmail)) { res.message = IdentityService.signInMessage(); return res; }
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) { res.message = 'No account found for that email — confirm the email or sign in.'; return res; }
        Order o = KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if (o == null) { res.message = 'No orders found on this account.'; return res; }
        res.orderNumber = o.OrderNumber;

        if (o.Fulfillment_Status__c == 'Cancelled' || o.Status == 'Canceled') {
            res.success = true; res.message = 'Order ' + o.OrderNumber + ' is already cancelled.'; return res;
        }
        if (!KwitkoServiceUtil.canCancel(o)) {
            res.message = 'Order ' + o.OrderNumber + ' is "' + KwitkoServiceUtil.fulfillment(o)
                + '" and can no longer be cancelled. Once delivered you can start a return instead.';
            return res;
        }
        if (r.confirmed != true) {
            res.message = 'Please confirm you want to cancel order ' + o.OrderNumber + ' and process the refund before I do it.';
            return res;
        }

        String reason = String.isBlank(r.reason) ? 'Customer request' : r.reason.trim();
        String custEmail = String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail;
        // WHO cancelled — full traceability. The chat agent runs as a Salesforce user, acting for the shopper.
        String who = 'Chat Agent (' + UserInfo.getName() + ') on behalf of ' + custEmail;

        // WooCommerce cancel + refund (real money) — callouts BEFORE any DML
        WooOrderActionService.WooResult cancelRes = WooOrderActionService.cancelOrder(o.Woo_Order_Id__c);
        Decimal amount = o.TotalAmount == null ? 0 : o.TotalAmount;
        WooOrderActionService.WooResult refundRes = WooOrderActionService.refundOrder(o.Woo_Order_Id__c, amount, 'Cancellation: ' + reason);
        res.refundIssued = refundRes.success; res.refundAmount = amount;

        String note = 'Cancelled by ' + who + ' on ' + System.now().format()
            + '. Reason: ' + reason + '. WooCommerce cancel ' + (cancelRes.success ? 'succeeded' : 'failed')
            + '; refund ' + (refundRes.success ? ('issued ' + amount.setScale(2)) : 'pending') + '.';

        o.Fulfillment_Status__c = 'Cancelled';
        o.Cancellation_Reason__c = reason;
        o.Cancelled_By__c = who;
        o.Cancellation_Source__c = 'Chat Agent';
        o.Cancelled_Date__c = System.now();
        o.Last_Status_Change__c = System.now();
        o.Status_Note__c = note;
        if (refundRes.success) o.Woo_Refund_Id__c = refundRes.refundId;
        update o;

        Case c = new Case(AccountId = acc.Id, ContactId = acc.PersonContactId, Order__c = o.Id,
            Woo_Order_Id__c = o.Woo_Order_Id__c, Origin = 'Chat', Status = 'New', Priority = 'Medium',
            Category__c = 'Order', Subject = 'Cancellation — order ' + o.OrderNumber,
            Summary__c = note, Description = note);
        insert c;
        res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;

        // Cross-agent context: any agent reading the journey now sees who/why this order was cancelled.
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = custEmail; lr.agent = 'Service'; lr.action = 'cancel_order'; lr.stage = 'Cancelled';
            lr.orderId = String.valueOf(o.Id);
            lr.result = 'Cancelled order ' + o.OrderNumber + ' by ' + who + '; reason: ' + reason
                + '; refund ' + (refundRes.success ? 'issued' : 'pending') + '; case ' + res.caseNumber;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.message = 'Order ' + o.OrderNumber + ' cancelled'
            + (refundRes.success ? (' and refunded ' + amount.setScale(2)) : ' (refund processing)')
            + '. Case ' + res.caseNumber + ' is tracking it.';
        return res;
    }
}
