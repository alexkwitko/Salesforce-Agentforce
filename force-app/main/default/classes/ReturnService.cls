/**
 * ReturnService — agent action that processes a return end-to-end:
 *   eligibility (order must be Delivered) → ReturnOrder + ReturnOrderLineItems (standard objects) →
 *   Order.Fulfillment_Status__c='Returned' → flag the Person Account (+Winback_Needed__c, reason) →
 *   WooCommerce refund (real money, per build decision) → generate + EMAIL a return shipping label →
 *   open a Returns Case. Idempotent per source order.
 */
public without sharing class ReturnService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Order Identifier (Woo id / order number, optional — defaults to latest)') public String orderIdentifier;
        @InvocableVariable(label='Items to Return' description='Comma-separated product names (or fragments) the shopper chose to return; leave blank or "all" for the whole order.') public String itemsToReturn;
        @InvocableVariable(label='Return Reason' description='Damaged | Wrong Item | Not As Described | Changed Mind | Quality | Other') public String reason;
        @InvocableVariable(label='Verified Email (pass loggedInEmail — required to process a return)') public String verifiedEmail;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms this return/refund.') public Boolean confirmed;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String returnOrderNumber;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public Decimal refundAmount;
        @InvocableVariable public Boolean refundIssued;
        @InvocableVariable public String returnLabelUrl;
        @InvocableVariable public String returnTracking;
        @InvocableVariable public Boolean labelEmailed;
        @InvocableVariable public String itemsReturned;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Process Return'
        description='Starts a return for a delivered order: creates the ReturnOrder, refunds in WooCommerce, emails a return shipping label, flags the customer, and opens a Returns case. Checks eligibility first.')
    public static List<Result> process(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doProcess(r));
        return out;
    }

    private static Result doProcess(Request r) {
        Result res = new Result(); res.success = false;
        // IDENTITY GATE: a return issues a refund — verified identity only.
        if (!IdentityService.isVerified(r.email, r.verifiedEmail)) { res.message = IdentityService.signInMessage(); return res; }
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) { res.message = 'No account found for that email — confirm the email or sign in.'; return res; }
        Order o = KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if (o == null) { res.message = 'No orders found on this account.'; return res; }

        // Eligibility — only carrier/shipment-delivered orders can be returned.
        if (!KwitkoServiceUtil.canReturn(o)) {
            res.message = 'Order ' + o.OrderNumber + ' is currently "' + KwitkoServiceUtil.fulfillment(o)
                + '" — returns are only available once a shipment/carrier event marks the order Delivered.';
            return res;
        }
        if (r.confirmed != true) {
            res.message = 'Please confirm you want to start a return for order ' + o.OrderNumber + ' before I process it.';
            return res;
        }
        // The ReturnOrder validation rule still checks Order.Fulfillment_Status__c. If the new
        // shipment truth layer proved delivery before the legacy Order field was refreshed, align it.
        if (o.Fulfillment_Status__c != 'Delivered') {
            update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered', Last_Status_Change__c = System.now(),
                Status_Note__c = 'Delivery confirmed from shipment truth layer before return processing.');
            o.Fulfillment_Status__c = 'Delivered';
        }

        // Idempotency — one active return per order.
        List<ReturnOrder> existing = [SELECT Id, ReturnOrderNumber FROM ReturnOrder WHERE Order__c = :o.Id LIMIT 1];
        if (!existing.isEmpty()) {
            res.message = 'A return is already on file for order ' + o.OrderNumber + ' (' + existing[0].ReturnOrderNumber + ').';
            res.returnOrderNumber = existing[0].ReturnOrderNumber;
            res.success = true;
            return res;
        }

        String reason = normReason(r.reason);

        // --- ITEM SELECTION: return only the item(s) the shopper chose (blank/"all" = whole order) ---
        List<OrderItem> allItems = [SELECT Product2Id, Product2.Name, Quantity, UnitPrice, TotalPrice FROM OrderItem WHERE OrderId = :o.Id];
        List<OrderItem> selected = selectItems(allItems, r.itemsToReturn);
        if (selected.isEmpty()) {
            res.message = 'I couldn\'t match "' + r.itemsToReturn + '" to an item on order ' + o.OrderNumber
                + '. This order has: ' + itemList(allItems) + '. Which would you like to return — or say "all"?';
            return res;
        }
        Boolean partial = selected.size() < allItems.size();
        Decimal amount = 0;
        for (OrderItem oi : selected) {
            amount += (oi.TotalPrice != null ? oi.TotalPrice
                : (oi.UnitPrice == null ? 0 : oi.UnitPrice * (oi.Quantity == null ? 1 : oi.Quantity)));
        }
        if (amount == 0 && !partial) amount = (o.TotalAmount == null ? 0 : o.TotalAmount);
        res.refundAmount = amount;
        res.itemsReturned = itemList(selected);

        // ---- CALLOUTS FIRST (no DML before HTTP callouts) ----
        WooOrderActionService.WooResult wr = WooOrderActionService.refundOrder(o.Woo_Order_Id__c, amount, 'Return (' + (partial ? res.itemsReturned : 'all items') + '): ' + reason);
        res.refundIssued = wr.success;
        ShippingService.LabelResult lbl = ShippingService.buildReturnLabel(o.OrderNumber);  // no DML/callout
        res.returnLabelUrl = lbl.labelUrl; res.returnTracking = lbl.trackingNumber;

        // ---- DML PHASE ----
        // 1) ReturnOrder + line items (standard objects) — only the selected items
        ReturnOrder ro = new ReturnOrder(AccountId = acc.Id, Order__c = o.Id, Return_Reason__c = reason,
            Return_Label_Url__c = lbl.labelUrl, Return_Tracking__c = lbl.trackingNumber);
        if (wr.success) { ro.Woo_Refund_Id__c = wr.refundId; ro.Refund_Amount__c = amount; }
        insert ro;
        List<ReturnOrderLineItem> lines = new List<ReturnOrderLineItem>();
        for (OrderItem oi : selected) {
            lines.add(new ReturnOrderLineItem(
                ReturnOrderId = ro.Id, Product2Id = oi.Product2Id,
                QuantityReturned = (oi.Quantity == null ? 1 : oi.Quantity)));
        }
        if (!lines.isEmpty()) insert lines;

        // 2) Order lifecycle (with traceability)
        String who = 'Chat Agent (' + UserInfo.getName() + ') on behalf of ' + (String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail);
        String rnote = 'Return processed by ' + who + ' on ' + System.now().format() + '. Reason: ' + reason
            + '. Refund ' + (wr.success ? ('issued ' + amount.setScale(2)) : 'pending') + '. Return label ' + lbl.trackingNumber + '.';
        o.Fulfillment_Status__c = wr.success ? 'Refunded' : 'Returned';
        o.Last_Status_Change__c = System.now();
        o.Status_Note__c = rnote;
        if (wr.success) o.Woo_Refund_Id__c = wr.refundId;
        update o;

        // 3) Flag the customer for the Growth win-back (triggers Winback_On_Return flow).
        // Use a fresh sObject so we never try to write the Person Account read-only Name field.
        update new Account(Id = acc.Id,
            Has_Returned_Order__c = true,
            Last_Return_Reason__c = reason,
            Last_Return_Date__c = Date.today(),
            Return_Count__c = (acc.Return_Count__c == null ? 0 : acc.Return_Count__c) + 1,
            Winback_Needed__c = true);
        DataCloudAugmentationService.refreshAccount(acc.Id);

        // 4) Return shipment (best-effort) + Returns Case
        ShippingService.createReturnShipment(lbl, o.OrderNumber, o.Id);
        Case c = new Case(AccountId = acc.Id, ContactId = acc.PersonContactId, Order__c = o.Id,
            Woo_Order_Id__c = o.Woo_Order_Id__c, Origin = 'Chat', Status = 'New', Priority = 'Medium',
            Category__c = 'Returns', Subject = 'Return started — order ' + o.OrderNumber,
            Summary__c = rnote, Description = rnote);
        insert c;
        res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;

        // Cross-agent context: log the return so every agent sees it on the journey.
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail; lr.agent = 'Service';
            lr.action = 'process_return'; lr.stage = 'Returned'; lr.orderId = String.valueOf(o.Id);
            lr.result = 'Return for order ' + o.OrderNumber + ' by ' + who + '; reason: ' + reason
                + '; refund ' + (wr.success ? 'issued' : 'pending') + '; case ' + res.caseNumber;
            if (String.isNotBlank(lr.email)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        // 5) Email the label (Messaging.sendEmail is allowed after DML)
        res.labelEmailed = emailLabel(acc.PersonEmail, o.OrderNumber, lbl);

        ro = [SELECT ReturnOrderNumber FROM ReturnOrder WHERE Id = :ro.Id LIMIT 1];
        res.returnOrderNumber = ro.ReturnOrderNumber;
        res.success = true;
        res.message = 'Return ' + ro.ReturnOrderNumber + ' created for order ' + o.OrderNumber
            + ' (' + (partial ? 'items: ' + res.itemsReturned : 'all items') + '). '
            + (wr.success ? ('Refund of ' + amount.setScale(2) + ' issued. ') : 'Refund is being processed. ')
            + (res.labelEmailed ? 'A prepaid return label was emailed to you' : 'Return label ready')
            + ' (tracking ' + lbl.trackingNumber + '). Case ' + res.caseNumber + ' is tracking it.';
        return res;
    }

    private static Boolean emailLabel(String toEmail, String orderNumber, ShippingService.LabelResult lbl) {
        if (String.isBlank(toEmail)) return false;
        EmailService.Request er = new EmailService.Request();
        er.toEmail = toEmail;
        er.subject = 'Your Kwitko Coffee return label — order ' + orderNumber;
        er.htmlBody = '<p>Hi,</p><p>Your return for order <strong>' + orderNumber + '</strong> is set up. '
            + 'Use the prepaid label below to ship the items back:</p>'
            + '<p><a href="' + lbl.labelUrl + '">Download your return shipping label</a><br/>'
            + 'Tracking: <strong>' + lbl.trackingNumber + '</strong></p>'
            + '<p>Your refund is on its way. Thanks for giving us a chance to make it right.<br/>— Kwitko Coffee Co.</p>';
        er.recordId = null; // transactional: not gated by marketing consent
        er.isTransactional = true;
        EmailService.Response resp = EmailService.send(new List<EmailService.Request>{ er })[0];
        return resp.success;
    }

    private static String normReason(String s) {
        if (String.isBlank(s)) return 'Other';
        String t = s.trim().toLowerCase();
        if (t.contains('damag')) return 'Damaged';
        if (t.contains('wrong')) return 'Wrong Item';
        if (t.contains('describ')) return 'Not As Described';
        if (t.contains('mind') || t.contains('changed')) return 'Changed Mind';
        if (t.contains('qualit') || t.contains('taste') || t.contains('stale')) return 'Quality';
        return 'Other';
    }

    /** Choose which OrderItems to return. Blank / "all" / "everything" / "whole order" → all items.
     *  Otherwise match each comma-separated fragment against the product name (case-insensitive contains). */
    private static List<OrderItem> selectItems(List<OrderItem> all, String sel) {
        String s = (sel == null) ? '' : sel.trim().toLowerCase();
        if (String.isBlank(s) || s == 'all' || s == 'everything' || s == 'all items' || s.contains('whole order') || s.contains('entire order')) {
            return all;
        }
        List<String> fragments = new List<String>();
        for (String f : s.split(',')) { if (String.isNotBlank(f)) fragments.add(f.trim()); }
        List<OrderItem> picked = new List<OrderItem>();
        Set<Id> seen = new Set<Id>();
        for (OrderItem oi : all) {
            String name = (oi.Product2 != null && oi.Product2.Name != null) ? oi.Product2.Name.toLowerCase() : '';
            for (String frag : fragments) {
                if (name.contains(frag) || frag.contains(name)) {
                    if (!seen.contains(oi.Id)) { picked.add(oi); seen.add(oi.Id); }
                    break;
                }
            }
        }
        return picked;
    }

    /** Human-readable "2× Ethiopia Yirgacheffe, 1× House Blend" list. */
    private static String itemList(List<OrderItem> items) {
        List<String> parts = new List<String>();
        for (OrderItem oi : items) {
            Integer q = (oi.Quantity == null) ? 1 : oi.Quantity.intValue();
            String nm = (oi.Product2 != null && oi.Product2.Name != null) ? oi.Product2.Name : 'item';
            parts.add(q + '× ' + nm);
        }
        return String.join(parts, ', ');
    }
}
