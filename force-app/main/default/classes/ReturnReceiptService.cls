/**
 * Internal/automation action for the supply-chain step: when returned merchandise is received,
 * issue the WooCommerce refund, close the ReturnOrder, close the Returns case, and record the audit trail.
 */
public without sharing class ReturnReceiptService {

    public class Request {
        @InvocableVariable(label='Return Order Number') public String returnOrderNumber;
        @InvocableVariable(label='Order Identifier (Woo id / order number)') public String orderIdentifier;
        @InvocableVariable(label='Return Tracking Number') public String returnTracking;
        @InvocableVariable(label='Received Note') public String receivedNote;
        @InvocableVariable(label='Confirmed Received' description='Must be true when the warehouse/supply-chain step confirms the merchandise was received.') public Boolean confirmed;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String returnOrderNumber;
        @InvocableVariable public String orderNumber;
        @InvocableVariable public Decimal refundAmount;
        @InvocableVariable public Boolean refundIssued;
        @InvocableVariable public String wooRefundId;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Receive Return and Process Refund'
        description='Internal supply-chain step: after returned merchandise is received, issues the WooCommerce refund and closes the return case.')
    public static List<Result> receive(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doReceive(r));
        return out;
    }

    private static Result doReceive(Request r) {
        Result res = new Result();
        res.success = false;
        res.refundIssued = false;
        if (r == null || r.confirmed != true) {
            res.message = 'Confirm the returned merchandise was received before issuing the WooCommerce refund.';
            return res;
        }

        ReturnOrder ro = findReturnOrder(r);
        if (ro == null) {
            res.message = 'No matching open return was found.';
            return res;
        }
        res.returnOrderNumber = ro.ReturnOrderNumber;
        if (String.isNotBlank(ro.Woo_Refund_Id__c) || ro.Status == 'Closed') {
            res.success = true;
            res.refundIssued = String.isNotBlank(ro.Woo_Refund_Id__c);
            res.wooRefundId = ro.Woo_Refund_Id__c;
            res.caseNumber = existingOrAuditCaseNumber(ro,
                'Return ' + ro.ReturnOrderNumber + ' is already closed'
                    + (String.isNotBlank(ro.Woo_Refund_Id__c) ? ' with Woo refund ' + ro.Woo_Refund_Id__c + '.' : '.'));
            res.message = 'Return ' + ro.ReturnOrderNumber + ' is already closed'
                + (String.isNotBlank(ro.Woo_Refund_Id__c) ? ' with Woo refund ' + ro.Woo_Refund_Id__c + '.' : '.');
            return res;
        }

        Order o = [
            SELECT Id, OrderNumber, Woo_Order_Id__c, AccountId, Account.PersonEmail, Account.PersonContactId
            FROM Order
            WHERE Id = :ro.Order__c
            LIMIT 1
        ];
        res.orderNumber = KwitkoServiceUtil.displayOrderNumber(o);
        if (String.isBlank(o.Woo_Order_Id__c)) {
            res.message = 'The source order has no WooCommerce order id, so the refund cannot be issued in Woo.';
            res.caseNumber = openFailureCase(o, ro, res.message);
            return res;
        }

        List<ReturnOrderLineItem> lines = [
            SELECT Id, OrderItemId, Product2Id, Product2.Name, QuantityReturned, QuantityReceived, UnitPrice, Woo_Line_Item_Id__c
            FROM ReturnOrderLineItem
            WHERE ReturnOrderId = :ro.Id
        ];
        backfillReturnLineWooIds(ro, lines);
        Decimal amount = ro.Refund_Amount__c == null ? 0 : ro.Refund_Amount__c;
        if (amount <= 0) {
            for (ReturnOrderLineItem line : lines) amount += lineAmount(line);
        }
        if (amount <= 0) {
            res.message = 'The return has no refundable amount recorded.';
            res.caseNumber = openFailureCase(o, ro, res.message);
            return res;
        }
        res.refundAmount = amount;

        List<WooOrderActionService.RefundLine> refundLines = buildRefundLines(lines);
        WooOrderActionService.WooResult refund = WooOrderActionService.refundOrder(
            o.Woo_Order_Id__c,
            amount,
            'Return received for ' + ro.ReturnOrderNumber + ': ' + safeNote(r.receivedNote),
            refundLines
        );
        if (!refund.success) {
            res.message = 'Returned merchandise was marked received, but the WooCommerce refund failed: ' + refund.message;
            res.caseNumber = openFailureCase(o, ro, res.message);
            return res;
        }
        WooOrderActionService.WooResult noteRes = WooOrderActionService.addCustomerNote(
            o.Woo_Order_Id__c,
            'Kwitko Coffee received your returned merchandise for ' + res.orderNumber
                + '. Refund ' + refund.refundId + ' for ' + amount.setScale(2) + ' has been processed.',
            true
        );

        String resolution = 'Returned merchandise received on ' + System.now().format()
            + '. WooCommerce refund ' + refund.refundId + ' processed for ' + amount.setScale(2)
            + '. Receipt note: ' + safeNote(r.receivedNote)
            + '. Woo customer notification ' + (noteRes.success ? 'created' : 'failed') + '.';

        ro.Status = 'Closed';
        ro.Woo_Refund_Id__c = refund.refundId;
        ro.Refund_Amount__c = amount;
        update ro;

        List<ReturnOrderLineItem> lineUpdates = new List<ReturnOrderLineItem>();
        for (ReturnOrderLineItem line : lines) {
            lineUpdates.add(new ReturnOrderLineItem(
                Id = line.Id,
                OrderItemId = line.OrderItemId,
                Woo_Line_Item_Id__c = line.Woo_Line_Item_Id__c,
                QuantityReceived = line.QuantityReturned
            ));
        }
        if (!lineUpdates.isEmpty()) update lineUpdates;

        update new Order(
            Id = o.Id,
            Fulfillment_Status__c = 'Refunded',
            Payment_Status__c = 'Refunded',
            Woo_Refund_Id__c = refund.refundId,
            Last_Status_Change__c = System.now(),
            Status_Note__c = resolution
        );

        List<Case> cases = ro.CaseId == null
            ? new List<Case>()
            : [SELECT Id, CaseNumber, Description FROM Case WHERE Id = :ro.CaseId LIMIT 1];
        if (cases.isEmpty()) {
            cases = [
                SELECT Id, CaseNumber, Description
                FROM Case
                WHERE Order__c = :o.Id
                  AND Category__c = 'Returns'
                  AND Status != 'Closed'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
        }
        if (!cases.isEmpty()) {
            Case c = cases[0];
            c.Status = 'Closed';
            c.Resolution__c = resolution;
            c.Resolved_By__c = 'Return receipt automation (' + UserInfo.getName() + ')';
            c.Description = appendSection(c.Description, 'Return receipt resolution', resolution);
            update c;
            insert new Task(
                WhatId = c.Id,
                Subject = 'Return received and refund processed',
                Status = 'Completed',
                Priority = 'Normal',
                ActivityDate = Date.today(),
                Description = resolution
            );
            res.caseNumber = c.CaseNumber;
        } else {
            Case c = new Case(
                AccountId = o.AccountId,
                ContactId = o.Account.PersonContactId,
                Order__c = o.Id,
                Woo_Order_Id__c = o.Woo_Order_Id__c,
                Origin = 'WooCommerce',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = 'Returns',
                Subject = 'Return received and refund processed — order ' + res.orderNumber,
                Summary__c = resolution,
                Description = appendSection(null, 'Return receipt resolution', resolution),
                Resolution__c = resolution,
                Resolved_By__c = 'Return receipt automation (' + UserInfo.getName() + ')'
            );
            insert c;
            insert new Task(
                WhatId = c.Id,
                WhoId = o.Account.PersonContactId,
                Subject = 'Return received and refund processed',
                Status = 'Completed',
                Priority = 'Normal',
                ActivityDate = Date.today(),
                Description = resolution
            );
            res.caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        }

        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = o.Account.PersonEmail;
            lr.agent = 'Service';
            lr.action = 'receive_return_and_refund';
            lr.stage = 'Refunded';
            lr.orderId = String.valueOf(o.Id);
            lr.result = resolution;
            if (String.isNotBlank(lr.email)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('return receipt journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.refundIssued = true;
        res.wooRefundId = refund.refundId;
        res.message = 'Return ' + ro.ReturnOrderNumber + ' was received. WooCommerce refund '
            + refund.refundId + ' for ' + amount.setScale(2) + ' was processed'
            + (String.isNotBlank(res.caseNumber) ? ', and case ' + res.caseNumber + ' was closed.' : '.');
        return res;
    }

    private static ReturnOrder findReturnOrder(Request r) {
        if (String.isNotBlank(r.returnOrderNumber)) {
            String rn = r.returnOrderNumber.trim().replaceAll('^#+', '');
            List<ReturnOrder> ros = [
                SELECT Id, ReturnOrderNumber, Status, Order__c, CaseId, Refund_Amount__c, Woo_Refund_Id__c
                FROM ReturnOrder
                WHERE ReturnOrderNumber = :rn
                LIMIT 1
            ];
            if (!ros.isEmpty()) return ros[0];
        }
        if (String.isNotBlank(r.returnTracking)) {
            List<ReturnOrder> ros = [
                SELECT Id, ReturnOrderNumber, Status, Order__c, CaseId, Refund_Amount__c, Woo_Refund_Id__c
                FROM ReturnOrder
                WHERE Return_Tracking__c = :r.returnTracking.trim()
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!ros.isEmpty()) return ros[0];
        }
        if (String.isBlank(r.orderIdentifier)) return null;
        Set<String> ids = orderIdentifierCandidates(r.orderIdentifier);
        List<Order> orders = [
            SELECT Id
            FROM Order
            WHERE Woo_Order_Id__c IN :ids OR OrderNumber IN :ids
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (orders.isEmpty()) return null;
        List<ReturnOrder> ros = [
            SELECT Id, ReturnOrderNumber, Status, Order__c, CaseId, Refund_Amount__c, Woo_Refund_Id__c
            FROM ReturnOrder
            WHERE Order__c = :orders[0].Id
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return ros.isEmpty() ? null : ros[0];
    }

    private static Set<String> orderIdentifierCandidates(String identifier) {
        Set<String> out = new Set<String>();
        if (String.isBlank(identifier)) return out;
        String raw = identifier.trim();
        out.add(raw);
        out.add(raw.replaceAll('^#+', ''));
        String digits = raw.replaceAll('[^0-9]', '');
        if (String.isNotBlank(digits)) {
            out.add(digits);
            String noZeros = digits.replaceFirst('^0+', '');
            if (String.isNotBlank(noZeros)) out.add(noZeros);
        }
        return out;
    }

    private static List<WooOrderActionService.RefundLine> buildRefundLines(List<ReturnOrderLineItem> lines) {
        List<WooOrderActionService.RefundLine> out = new List<WooOrderActionService.RefundLine>();
        for (ReturnOrderLineItem line : lines) {
            Decimal amt = lineAmount(line);
            if (String.isNotBlank(line.Woo_Line_Item_Id__c) && amt > 0) {
                out.add(new WooOrderActionService.RefundLine(line.Woo_Line_Item_Id__c, amt));
            }
        }
        return out;
    }

    private static void backfillReturnLineWooIds(ReturnOrder ro, List<ReturnOrderLineItem> lines) {
        if (ro == null || ro.Order__c == null || lines == null || lines.isEmpty()) return;
        Set<Id> orderItemIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (ReturnOrderLineItem line : lines) {
            if (String.isNotBlank(line.Woo_Line_Item_Id__c)) continue;
            if (line.OrderItemId != null) orderItemIds.add(line.OrderItemId);
            if (line.Product2Id != null) productIds.add(line.Product2Id);
        }
        if (orderItemIds.isEmpty() && productIds.isEmpty()) return;

        Map<Id, OrderItem> byId = new Map<Id, OrderItem>();
        Map<Id, List<OrderItem>> byProduct = new Map<Id, List<OrderItem>>();
        for (OrderItem item : [
            SELECT Id, Product2Id, Quantity, UnitPrice, Woo_Line_Item_Id__c
            FROM OrderItem
            WHERE OrderId = :ro.Order__c
              AND (Id IN :orderItemIds OR Product2Id IN :productIds)
              AND Woo_Line_Item_Id__c != null
        ]) {
            byId.put(item.Id, item);
            if (!byProduct.containsKey(item.Product2Id)) byProduct.put(item.Product2Id, new List<OrderItem>());
            byProduct.get(item.Product2Id).add(item);
        }

        for (ReturnOrderLineItem line : lines) {
            if (String.isNotBlank(line.Woo_Line_Item_Id__c)) continue;
            OrderItem source = line.OrderItemId == null ? null : byId.get(line.OrderItemId);
            if (source == null) source = uniqueSourceLine(byProduct.get(line.Product2Id), line);
            if (source == null || String.isBlank(source.Woo_Line_Item_Id__c)) continue;
            line.OrderItemId = source.Id;
            line.Woo_Line_Item_Id__c = source.Woo_Line_Item_Id__c;
        }
    }

    private static OrderItem uniqueSourceLine(List<OrderItem> candidates, ReturnOrderLineItem line) {
        if (candidates == null || candidates.isEmpty()) return null;
        List<OrderItem> exact = new List<OrderItem>();
        for (OrderItem item : candidates) {
            Boolean qtyMatches = line.QuantityReturned == null || item.Quantity == line.QuantityReturned;
            Boolean unitMatches = line.UnitPrice == null || item.UnitPrice == line.UnitPrice;
            if (qtyMatches && unitMatches) exact.add(item);
        }
        if (exact.size() == 1) return exact[0];
        if (candidates.size() == 1) return candidates[0];
        return null;
    }

    private static Decimal lineAmount(ReturnOrderLineItem line) {
        Decimal qty = line.QuantityReturned == null || line.QuantityReturned <= 0 ? 1 : line.QuantityReturned;
        Decimal unit = line.UnitPrice == null ? 0 : line.UnitPrice;
        return unit * qty;
    }

    private static String safeNote(String note) {
        return String.isBlank(note) ? 'Return received.' : note.trim();
    }

    private static String appendSection(String existing, String title, String body) {
        String prefix = String.isBlank(existing) ? '' : existing + '\n\n';
        return prefix + '--- ' + title + ' ---\n' + body;
    }

    private static String existingOrAuditCaseNumber(ReturnOrder ro, String resolution) {
        if (ro == null || ro.Order__c == null) return null;
        try {
            if (ro.CaseId != null) {
                List<Case> linkedCases = [SELECT CaseNumber FROM Case WHERE Id = :ro.CaseId LIMIT 1];
                if (!linkedCases.isEmpty()) return linkedCases[0].CaseNumber;
            }
            List<Case> cases = [
                SELECT Id, CaseNumber
                FROM Case
                WHERE Order__c = :ro.Order__c
                  AND Category__c = 'Returns'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!cases.isEmpty()) return cases[0].CaseNumber;

            Order o = [
                SELECT Id, Woo_Order_Id__c, AccountId, Account.PersonContactId
                FROM Order
                WHERE Id = :ro.Order__c
                LIMIT 1
            ];
            Case c = new Case(
                AccountId = o.AccountId,
                ContactId = o.Account.PersonContactId,
                Order__c = o.Id,
                Woo_Order_Id__c = o.Woo_Order_Id__c,
                Origin = 'WooCommerce',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = 'Returns',
                Subject = 'Return receipt already closed — ' + ro.ReturnOrderNumber,
                Summary__c = resolution,
                Description = appendSection(null, 'Return receipt audit', resolution),
                Resolution__c = resolution,
                Resolved_By__c = 'Return receipt automation (' + UserInfo.getName() + ')'
            );
            insert c;
            insert new Task(
                WhatId = c.Id,
                WhoId = o.Account.PersonContactId,
                Subject = 'Return receipt audit',
                Status = 'Completed',
                Priority = 'Normal',
                ActivityDate = Date.today(),
                Description = resolution
            );
            return [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        } catch (Exception e) {
            System.debug('return receipt audit case failed: ' + e.getMessage());
            return null;
        }
    }

    private static String openFailureCase(Order o, ReturnOrder ro, String message) {
        if (o == null || ro == null) return null;
        try {
            String summary = message + ' Human follow-up is required before this return can be closed.';
            Case c = new Case(
                AccountId = o.AccountId,
                ContactId = o.Account.PersonContactId,
                Order__c = o.Id,
                Woo_Order_Id__c = o.Woo_Order_Id__c,
                Origin = 'WooCommerce',
                Status = 'New',
                Priority = 'High',
                Category__c = 'Returns',
                Subject = 'Return receipt refund needs follow-up — ' + ro.ReturnOrderNumber,
                Summary__c = summary,
                Description = appendSection(null, 'Return receipt failure', summary)
            );
            insert c;
            insert new Task(
                WhatId = c.Id,
                WhoId = o.Account.PersonContactId,
                Subject = 'Return receipt refund follow-up',
                Status = 'Completed',
                Priority = 'High',
                ActivityDate = Date.today(),
                Description = summary
            );
            return [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1].CaseNumber;
        } catch (Exception e) {
            System.debug('return receipt failure case failed: ' + e.getMessage());
            return null;
        }
    }
}
