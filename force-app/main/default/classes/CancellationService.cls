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
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the cancellation conversation so the Case carries the chat trail.') public String chatSummary;
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
        if (acc == null) {
            res.message = 'No account found for that email — confirm the email or sign in.';
            res.caseNumber = solvedCaseNumber(null, null, r.email, null, null, 'Order',
                'Chat service: Cancellation answered', res.message, r.chatSummary);
            return res;
        }
        Order o = KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if (o == null) {
            res.message = 'No orders found on this account.';
            res.caseNumber = solvedCaseNumber(acc.Id, acc.PersonContactId, r.email, null, null, 'Order',
                'Chat service: Cancellation answered', res.message, r.chatSummary);
            return res;
        }
        String displayNo = KwitkoServiceUtil.displayOrderNumber(o);
        res.orderNumber = displayNo;

        if (o.Fulfillment_Status__c == 'Cancelled' || o.Status == 'Canceled') {
            res.success = true;
            res.message = 'Order ' + displayNo + ' is already cancelled.';
            res.caseNumber = solvedCaseNumber(acc.Id, acc.PersonContactId, r.email, o.Id, o.Woo_Order_Id__c,
                'Order', 'Chat service: Cancellation answered',
                'Order ' + displayNo + ' was already cancelled. Shopper was told no new cancellation was needed.',
                r.chatSummary);
            return res;
        }
        if (!KwitkoServiceUtil.canCancel(o)) {
            res.message = 'Order ' + displayNo + ' is "' + KwitkoServiceUtil.fulfillment(o)
                + '" and can no longer be cancelled. Once delivered you can start a return instead.';
            res.caseNumber = solvedCaseNumber(acc.Id, acc.PersonContactId, r.email, o.Id, o.Woo_Order_Id__c,
                'Order', 'Chat service: Cancellation answered', res.message, r.chatSummary);
            return res;
        }
        if (r.confirmed != true) {
            res.message = 'Please confirm you want to cancel order ' + displayNo + ' and process the refund before I do it.';
            return res;
        }

        String reason = String.isBlank(r.reason) ? 'Customer request' : r.reason.trim();
        String custEmail = String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail;
        // WHO cancelled — full traceability. The chat agent runs as a Salesforce user, acting for the shopper.
        String who = 'Chat Agent (' + UserInfo.getName() + ') on behalf of ' + custEmail;

        // WooCommerce cancel + refund (real money) — callouts BEFORE any DML
        WooOrderActionService.WooResult cancelRes = WooOrderActionService.cancelOrder(o.Woo_Order_Id__c);
        Decimal amount = o.Woo_Order_Total__c != null ? o.Woo_Order_Total__c : (o.TotalAmount == null ? 0 : o.TotalAmount);
        res.refundAmount = amount;

        String failedNote = 'Cancellation requested by ' + who + ' on ' + System.now().format()
            + '. Reason: ' + reason + '. WooCommerce cancel failed; no refund was attempted.';

        if (!cancelRes.success) {
            Case failed = new Case(AccountId = acc.Id, ContactId = acc.PersonContactId, Order__c = o.Id,
                Woo_Order_Id__c = o.Woo_Order_Id__c, Origin = 'Chat', Status = 'New', Priority = 'High',
                Category__c = 'Order', Subject = 'Cancellation failed — order ' + displayNo,
                Summary__c = failedNote + ' ' + cancelRes.message,
                Description = appendChatTranscript(failedNote + '\n\nWoo response: ' + cancelRes.message, r.chatSummary));
            insert failed;
            res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :failed.Id LIMIT 1].CaseNumber;
            insertChatTranscript(failed.Id, acc.PersonContactId, r.chatSummary);
            res.message = 'I could not complete the cancellation for order ' + displayNo
                + ' in WooCommerce. Case ' + res.caseNumber + ' was opened for human follow-up.';
            return res;
        }

        WooOrderActionService.WooResult refundRes = WooOrderActionService.refundOrder(o.Woo_Order_Id__c, amount, 'Cancellation: ' + reason);
        res.refundIssued = refundRes.success;

        String note = 'Cancelled by ' + who + ' on ' + System.now().format()
            + '. Reason: ' + reason + '. WooCommerce cancel succeeded'
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

        String caseStatus = refundRes.success ? 'Closed' : 'New';
        Case c = new Case(AccountId = acc.Id, ContactId = acc.PersonContactId, Order__c = o.Id,
            Woo_Order_Id__c = o.Woo_Order_Id__c, Origin = 'Chat', Status = caseStatus, Priority = 'Medium',
            Category__c = 'Order', Subject = 'Cancellation — order ' + displayNo,
            Summary__c = note, Description = appendChatTranscript(note, r.chatSummary));
        if (refundRes.success) {
            c.Resolution__c = note;
            c.Resolved_By__c = 'Chat Agent (' + UserInfo.getName() + ')';
        }
        insert c;
        res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        insertChatTranscript(c.Id, acc.PersonContactId, r.chatSummary);

        // Cross-agent context: any agent reading the journey now sees who/why this order was cancelled.
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = custEmail; lr.agent = 'Service'; lr.action = 'cancel_order'; lr.stage = 'Cancelled';
            lr.orderId = String.valueOf(o.Id);
            lr.result = 'Cancelled order ' + displayNo + ' by ' + who + '; reason: ' + reason
                + '; refund ' + (refundRes.success ? 'issued' : 'pending') + '; case ' + res.caseNumber;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.message = 'Order ' + displayNo + ' cancelled'
            + (refundRes.success ? (' and refunded ' + amount.setScale(2)) : ' (refund processing)')
            + '. Case ' + res.caseNumber + ' is tracking it.';
        return res;
    }

    private static String appendChatTranscript(String existing, String chatSummary) {
        return CaseTranscriptUtil.append(existing, chatSummary);
    }

    private static void insertChatTranscript(Id caseId, Id contactId, String chatSummary) {
        CaseTranscriptUtil.insertTask(caseId, contactId, chatSummary);
    }

    private static String solvedCaseNumber(
        Id accountId,
        Id contactId,
        String email,
        Id orderId,
        String wooOrderId,
        String category,
        String subject,
        String resolution,
        String chatSummary
    ) {
        Id caseId = CaseTranscriptUtil.insertSolvedCase(
            accountId,
            contactId,
            email,
            orderId,
            wooOrderId,
            category,
            subject,
            resolution,
            chatSummary
        );
        if (caseId == null) return null;
        List<Case> cases = [SELECT CaseNumber FROM Case WHERE Id = :caseId LIMIT 1];
        return cases.isEmpty() ? null : cases[0].CaseNumber;
    }
}
