/**
 * ReturnService — agent action that starts a return:
 *   eligibility (order must be Delivered) → ReturnOrder + ReturnOrderLineItems (standard objects) →
 *   Order.Fulfillment_Status__c='Return Pending' → flag the Person Account (+Winback_Needed__c, reason) →
 *   generate + send a return shipping label through WooCommerce → open a Returns Case.
 *   The WooCommerce refund is intentionally deferred until ReturnReceiptService confirms receipt.
 */
public without sharing class ReturnService {
    @TestVisible private static Boolean forceLabelBackupFailureInTests = false;

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Order Identifier (Woo id / order number, optional — defaults to latest)') public String orderIdentifier;
        @InvocableVariable(label='Items to Return' description='Comma-separated product names (or fragments) the shopper chose to return; leave blank or "all" for the whole order.') public String itemsToReturn;
        @InvocableVariable(label='Return Reason' description='Damaged | Wrong Item | Not As Described | Changed Mind | Quality | Other') public String reason;
        @InvocableVariable(label='Verified Email (pass loggedInEmail — required to process a return)') public String verifiedEmail;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms this return/refund.') public Boolean confirmed;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the return conversation so the Returns case carries the chat trail.') public String chatSummary;
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
        description='Starts a return for a delivered order: creates the ReturnOrder, sends a return shipping label, flags the customer, and opens a Returns case. The WooCommerce refund is processed only after returned merchandise is received.')
    public static List<Result> process(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doProcess(r));
        return out;
    }

    private static Result doProcess(Request r) {
        Result res = new Result(); res.success = false;
        // IDENTITY GATE: a return starts a money-impacting workflow, so use verified identity only.
        if (!IdentityService.isVerified(r.email, r.verifiedEmail)) { res.message = IdentityService.signInMessage(); return res; }
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) { res.message = 'No account found for that email — confirm the email or sign in.'; return res; }
        Order o = KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if (o == null) { res.message = 'No orders found on this account.'; return res; }
        String displayNo = KwitkoServiceUtil.displayOrderNumber(o);

        // Idempotency first: once a return exists, the source order moves to Return Pending.
        // A duplicate call should surface that existing workflow instead of failing eligibility.
        List<ReturnOrder> existing = [SELECT Id, ReturnOrderNumber, CaseId FROM ReturnOrder WHERE Order__c = :o.Id LIMIT 1];
        if (!existing.isEmpty()) {
            res.message = 'A return is already on file for order ' + displayNo + ' (' + existing[0].ReturnOrderNumber + ').';
            res.returnOrderNumber = existing[0].ReturnOrderNumber;
            res.caseNumber = createExistingReturnStatusCase(acc, o, displayNo, existing[0].ReturnOrderNumber, r.chatSummary);
            res.success = true;
            return res;
        }

        // Eligibility — only carrier/shipment-delivered orders can be returned.
        if (!KwitkoServiceUtil.canReturn(o)) {
            res.message = 'Order ' + displayNo + ' is currently "' + KwitkoServiceUtil.fulfillment(o)
                + '" — returns are only available once a shipment/carrier event marks the order Delivered.';
            return res;
        }
        if (r.confirmed != true) {
            res.message = 'Please confirm you want to start a return for order ' + displayNo + ' before I process it.';
            return res;
        }
        // The ReturnOrder validation rule still checks Order.Fulfillment_Status__c. If the new
        // shipment truth layer proved delivery before the legacy Order field was refreshed, align it.
        Boolean needsDeliveryAlignment = o.Fulfillment_Status__c != 'Delivered';

        String reason = normReason(r.reason);

        // --- ITEM SELECTION: return only the item(s) the shopper chose (blank/"all" = whole order) ---
        List<OrderItem> allItems = [
            SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, TotalPrice, Woo_Line_Item_Id__c
            FROM OrderItem
            WHERE OrderId = :o.Id
        ];
        List<ReturnLine> selected = selectItems(allItems, r.itemsToReturn);
        if (selected.isEmpty()) {
            res.message = 'I couldn\'t match "' + r.itemsToReturn + '" to an item on order ' + displayNo
                + '. This order has: ' + itemList(allItems) + '. Which would you like to return — or say "all"?';
            return res;
        }
        Boolean partial = !isWholeOrder(selected, allItems);
        Decimal amount = 0;
        for (ReturnLine line : selected) amount += line.amount;
        if (!partial && o.Woo_Order_Total__c != null) amount = o.Woo_Order_Total__c;
        if (amount == 0 && !partial) amount = (o.TotalAmount == null ? 0 : o.TotalAmount);
        res.refundAmount = amount;
        res.itemsReturned = itemList(selected);

        // ---- CALLOUTS FIRST (no DML before HTTP callouts) ----
        ShippingService.LabelResult lbl = ShippingService.buildReturnLabel(displayNo);  // no DML/callout
        res.returnLabelUrl = lbl.labelUrl; res.returnTracking = lbl.trackingNumber;
        WooOrderActionService.WooResult emailRes = WooOrderActionService.sendReturnLabelEmail(
            o.Woo_Order_Id__c,
            acc.PersonEmail,
            displayNo,
            lbl.labelUrl,
            lbl.trackingNumber,
            res.itemsReturned
        );
        WooOrderActionService.WooResult noteRes = WooOrderActionService.addCustomerNote(
            o.Woo_Order_Id__c,
            'Your Kwitko Coffee return for order ' + displayNo + ' has been started. '
                + 'Use this prepaid return label: ' + lbl.labelUrl + ' . Return tracking: ' + lbl.trackingNumber
                + '. Your refund will be processed after the returned merchandise is received.',
            true
        );
        res.refundIssued = false;

        // ---- DML PHASE ----
        if (needsDeliveryAlignment) {
            update new Order(Id = o.Id, Fulfillment_Status__c = 'Delivered', Last_Status_Change__c = System.now(),
                Status_Note__c = 'Delivery confirmed from shipment truth layer before return processing.');
            o.Fulfillment_Status__c = 'Delivered';
        }

        // 1) ReturnOrder + line items (standard objects) — only the selected items
        ReturnOrder ro = new ReturnOrder(AccountId = acc.Id, Order__c = o.Id, Return_Reason__c = reason,
            Return_Label_Url__c = lbl.labelUrl, Return_Tracking__c = lbl.trackingNumber,
            Refund_Amount__c = amount, Status = 'Submitted');
        insert ro;
        List<ReturnOrderLineItem> lines = new List<ReturnOrderLineItem>();
        for (ReturnLine line : selected) {
            lines.add(new ReturnOrderLineItem(
                ReturnOrderId = ro.Id, Product2Id = line.item.Product2Id,
                OrderItemId = line.item.Id,
                QuantityReturned = line.quantity,
                QuantityExpected = line.quantity,
                UnitPrice = line.unitAmount,
                ReasonForReturn = returnLineReason(reason),
                RepaymentMethod = 'Refund',
                Woo_Line_Item_Id__c = line.item.Woo_Line_Item_Id__c));
        }
        if (!lines.isEmpty()) insert lines;

        // 2) Order lifecycle (with traceability)
        String who = 'Chat Agent (' + UserInfo.getName() + ') on behalf of ' + (String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail);
        String rnote = 'Return started by ' + who + ' on ' + System.now().format() + '. Reason: ' + reason
            + '. Refund amount ' + amount.setScale(2) + ' pending merchandise receipt. Return label '
            + lbl.trackingNumber + '. Woo label email ' + (emailRes.success ? 'sent' : 'failed')
            + '; Woo label note ' + (noteRes.success ? 'created' : 'failed') + '.';
        o.Fulfillment_Status__c = 'Return Pending';
        o.Last_Status_Change__c = System.now();
        o.Status_Note__c = rnote;
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
        DataCloudAugmentationService.refreshAccountFromDataCloudAsync(acc.Id);

        // 4) Return shipment (best-effort) + Returns Case
        ShippingService.createReturnShipment(lbl, displayNo, o.Id);
        Case c = new Case(AccountId = acc.Id, ContactId = acc.PersonContactId, Order__c = o.Id,
            Woo_Order_Id__c = o.Woo_Order_Id__c, Origin = 'Chat', Status = 'New', Priority = 'Medium',
            Category__c = 'Returns', Subject = 'Return started — order ' + displayNo,
            Summary__c = rnote, Description = appendChatTranscript(rnote, r.chatSummary));
        insert c;
        update new ReturnOrder(Id = ro.Id, CaseId = c.Id);
        res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        insertChatTranscript(c.Id, acc.PersonContactId, r.chatSummary);

        // Cross-agent context: log the return so every agent sees it on the journey.
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = String.isBlank(acc.PersonEmail) ? r.email : acc.PersonEmail; lr.agent = 'Service';
            lr.action = 'process_return'; lr.stage = 'Return Pending'; lr.orderId = String.valueOf(o.Id);
            lr.result = 'Return for order ' + displayNo + ' by ' + who + '; reason: ' + reason
                + '; refund pending receipt; case ' + res.caseNumber;
            lr.chatSummary = r.chatSummary;
            if (String.isNotBlank(lr.email)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        // 5) Woo sends the label. Salesforce email is only a backup if Woo cannot send it.
        res.labelEmailed = emailRes.success || emailLabel(acc.PersonEmail, displayNo, lbl);

        ro = [SELECT ReturnOrderNumber FROM ReturnOrder WHERE Id = :ro.Id LIMIT 1];
        res.returnOrderNumber = ro.ReturnOrderNumber;
        res.success = true;
        res.message = 'Return ' + ro.ReturnOrderNumber + ' created for order ' + displayNo
            + ' (' + (partial ? 'items: ' + res.itemsReturned : 'all items') + '). '
            + 'Expected refund amount is ' + amount.setScale(2)
            + ', and the refund will be processed after the returned merchandise is received. '
            + (res.labelEmailed
                ? 'A prepaid return label was sent to you'
                : 'A prepaid return label is ready, but the label email could not be sent automatically. Use this link now: ' + lbl.labelUrl)
            + ' (tracking ' + lbl.trackingNumber + '). Case ' + res.caseNumber + ' is tracking it.';
        return res;
    }

    private static Boolean emailLabel(String toEmail, String orderNumber, ShippingService.LabelResult lbl) {
        if (String.isBlank(toEmail)) return false;
        if (Test.isRunningTest() && forceLabelBackupFailureInTests) return false;
        EmailService.Request er = new EmailService.Request();
        er.toEmail = toEmail;
        er.subject = 'Your Kwitko Coffee return label — order ' + orderNumber;
        er.htmlBody = '<p>Hi,</p><p>Your return for order <strong>' + orderNumber + '</strong> is set up. '
            + 'Use the prepaid label below to ship the items back:</p>'
            + '<p><a href="' + lbl.labelUrl + '">Download your return shipping label</a><br/>'
            + 'Tracking: <strong>' + lbl.trackingNumber + '</strong></p>'
            + '<p>Your refund will be processed after the returned merchandise is received. '
            + 'Thanks for giving us a chance to make it right.<br/>— Kwitko Coffee Co.</p>';
        er.recordId = null; // transactional: not gated by marketing consent
        er.isTransactional = true;
        EmailService.Response resp = EmailService.send(new List<EmailService.Request>{ er })[0];
        return resp.success;
    }

    private static String createExistingReturnStatusCase(
        Account acc,
        Order orderRecord,
        String displayNo,
        String returnOrderNumber,
        String chatSummary
    ) {
        try {
            String summary = 'Return ' + returnOrderNumber + ' is already on file for order ' + displayNo
                + '. Shopper was told the existing return is still the active return workflow and no duplicate return was created.';
            Case c = new Case(
                AccountId = acc.Id,
                ContactId = acc.PersonContactId,
                Order__c = orderRecord.Id,
                Woo_Order_Id__c = orderRecord.Woo_Order_Id__c,
                Origin = 'Chat',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = 'Returns',
                Subject = 'Chat service: Return status answered',
                Summary__c = summary,
                Description = appendChatTranscript(summary, chatSummary),
                Resolution__c = summary,
                Resolved_By__c = 'Chat Agent (' + UserInfo.getName() + ')'
            );
            insert c;
            insertChatTranscript(c.Id, acc.PersonContactId, chatSummary);
            return [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        } catch (Exception e) {
            System.debug('existing return status case creation failed: ' + e.getMessage());
            return null;
        }
    }

    private static String caseNumber(Id caseId) {
        if (caseId == null) return null;
        List<Case> cases = [SELECT CaseNumber FROM Case WHERE Id = :caseId LIMIT 1];
        return cases.isEmpty() ? null : cases[0].CaseNumber;
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

    private static String returnLineReason(String reason) {
        if (reason == 'Damaged') return 'Damaged';
        if (reason == 'Wrong Item') return 'Wrong Item';
        if (reason == 'Quality' || reason == 'Not As Described' || reason == 'Changed Mind') return 'Not Satisfied';
        return 'Other';
    }

    private class ReturnLine {
        OrderItem item;
        Decimal quantity;
        Decimal unitAmount;
        Decimal amount;
        ReturnLine(OrderItem item, Decimal quantity) {
            this.item = item;
            this.quantity = quantity;
            Decimal fullQty = item.Quantity == null || item.Quantity <= 0 ? 1 : item.Quantity;
            this.unitAmount = item.TotalPrice != null && fullQty > 0
                ? item.TotalPrice / fullQty
                : (item.UnitPrice == null ? 0 : item.UnitPrice);
            this.amount = this.unitAmount * this.quantity;
        }
    }

    private class SelectionFragment {
        String productText;
        Decimal quantity;
    }

    /** Choose which OrderItems to return. Blank / "all" / "everything" / "whole order" → all items.
     *  Otherwise match each comma-separated fragment against the product name (case-insensitive contains). */
    private static List<ReturnLine> selectItems(List<OrderItem> all, String sel) {
        String s = (sel == null) ? '' : sel.trim().toLowerCase();
        if (String.isBlank(s) || s == 'all' || s == 'everything' || s == 'all items' || s.contains('whole order') || s.contains('entire order')) {
            List<ReturnLine> everything = new List<ReturnLine>();
            for (OrderItem oi : all) everything.add(new ReturnLine(oi, oi.Quantity == null ? 1 : oi.Quantity));
            return everything;
        }
        List<SelectionFragment> fragments = new List<SelectionFragment>();
        for (String f : s.split(',')) {
            if (String.isNotBlank(f)) fragments.add(parseFragment(f.trim()));
        }
        Map<Id, ReturnLine> picked = new Map<Id, ReturnLine>();
        for (SelectionFragment frag : fragments) {
            String needle = normalizeSelector(frag.productText);
            if (String.isBlank(needle)) continue;
            for (OrderItem oi : all) {
                String name = normalizeSelector(oi.Product2 != null ? oi.Product2.Name : null);
                if (name.contains(needle) || needle.contains(name)) {
                    Decimal available = oi.Quantity == null || oi.Quantity <= 0 ? 1 : oi.Quantity;
                    Decimal qty = frag.quantity == null || frag.quantity <= 0 ? available : minDecimal(frag.quantity, available);
                    if (picked.containsKey(oi.Id)) {
                        picked.get(oi.Id).quantity = minDecimal(available, picked.get(oi.Id).quantity + qty);
                        picked.get(oi.Id).amount = picked.get(oi.Id).unitAmount * picked.get(oi.Id).quantity;
                    } else {
                        picked.put(oi.Id, new ReturnLine(oi, qty));
                    }
                    break;
                }
            }
        }
        return picked.values();
    }

    private static SelectionFragment parseFragment(String raw) {
        SelectionFragment out = new SelectionFragment();
        out.productText = raw;
        String s = raw == null ? '' : raw.trim().toLowerCase();
        Matcher m = Pattern.compile('^(\\d+(?:\\.\\d+)?)\\s*(?:x|of|qty|quantity)?\\s+(.+)$').matcher(s);
        if (m.matches()) {
            out.quantity = Decimal.valueOf(m.group(1));
            out.productText = m.group(2);
            return out;
        }
        m = Pattern.compile('^(.+?)\\s+(?:x|qty|quantity)\\s*(\\d+(?:\\.\\d+)?)$').matcher(s);
        if (m.matches()) {
            out.productText = m.group(1);
            out.quantity = Decimal.valueOf(m.group(2));
        }
        return out;
    }

    private static String normalizeSelector(String s) {
        if (String.isBlank(s)) return '';
        return s.toLowerCase()
            .replaceAll('(?i)\\b(the|a|an|bag|bags|item|items|return|refund|all)\\b', ' ')
            .replaceAll('[^a-z0-9]+', ' ')
            .replaceAll('\\s+', ' ')
            .trim();
    }

    private static Boolean isWholeOrder(List<ReturnLine> selected, List<OrderItem> all) {
        if (selected.size() != all.size()) return false;
        Map<Id, Decimal> selectedQty = new Map<Id, Decimal>();
        for (ReturnLine line : selected) selectedQty.put(line.item.Id, line.quantity);
        for (OrderItem oi : all) {
            Decimal qty = oi.Quantity == null || oi.Quantity <= 0 ? 1 : oi.Quantity;
            if (!selectedQty.containsKey(oi.Id) || selectedQty.get(oi.Id) < qty) return false;
        }
        return true;
    }

    private static Decimal minDecimal(Decimal a, Decimal b) {
        return a <= b ? a : b;
    }

    private static String qtyLabel(Decimal qty) {
        String out = String.valueOf(qty == null ? 0 : qty);
        return out.endsWith('.0') ? out.substring(0, out.length() - 2) : out;
    }

    private static String appendChatTranscript(String existing, String chatSummary) {
        return CaseTranscriptUtil.append(existing, chatSummary);
    }

    private static void insertChatTranscript(Id caseId, Id contactId, String chatSummary) {
        CaseTranscriptUtil.insertTask(caseId, contactId, chatSummary);
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

    private static String itemList(List<ReturnLine> items) {
        List<String> parts = new List<String>();
        for (ReturnLine line : items) {
            String nm = (line.item.Product2 != null && line.item.Product2.Name != null) ? line.item.Product2.Name : 'item';
            parts.add(qtyLabel(line.quantity) + '× ' + nm);
        }
        return String.join(parts, ', ');
    }
}
