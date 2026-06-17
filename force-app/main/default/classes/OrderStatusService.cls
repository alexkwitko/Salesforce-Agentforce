/**
 * OrderStatusService — read-only agent action: returns a shopper's order status, items, fulfillment
 * stage, and what actions are currently allowed (cancel/return) per the lifecycle eligibility matrix.
 * The Service subagent uses this for "where's my order / can I return this" questions. PII-light:
 * returns the shopper's OWN order only (scoped by account email).
 */
public without sharing class OrderStatusService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Order Identifier (Woo id / order number, optional — defaults to latest)') public String orderIdentifier;
        @InvocableVariable(label='Verified Email (the signed-in verified email — pass loggedInEmail; required to return order data)') public String verifiedEmail;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the conversation so the solved service Case has context.')
        public String chatSummary;
    }
    public class Result {
        @InvocableVariable public Boolean found;
        @InvocableVariable public String orderNumber;
        @InvocableVariable public String wooOrderId;
        @InvocableVariable public String fulfillmentStatus;
        @InvocableVariable public String orderStatus;
        @InvocableVariable public Decimal total;
        @InvocableVariable public String orderedDate;
        @InvocableVariable public String itemsSummary;
        @InvocableVariable public Boolean canCancel;
        @InvocableVariable public Boolean canReturn;
        @InvocableVariable public String cancelledBy;        // WHO cancelled (traceability)
        @InvocableVariable public String cancellationReason; // why it was cancelled
        @InvocableVariable public String cancelledDate;      // when it was cancelled
        @InvocableVariable public String statusNote;         // grounded human-readable note on the latest status change
        @InvocableVariable public String returnStatus;       // return lifecycle for this order, if any
        @InvocableVariable public Integer openCaseCount;     // open support cases on this order
        @InvocableVariable public String trackingNumber;     // carrier tracking, if shipped
        @InvocableVariable public String carrier;
        @InvocableVariable public String trackingUrl;
        @InvocableVariable public String statusSource;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public String openCaseSummary;
        @InvocableVariable public String summary;
    }

    @InvocableMethod(label='Get Order Status'
        description='Returns the order status, items, fulfillment stage, and whether it can currently be cancelled or returned. Read-only and scoped to the customer own orders.')
    public static List<Result> get(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r));
        return out;
    }

    private static Result build(Request r) {
        Result res = new Result(); res.found = false;
        // ── IDENTITY GATE: order status is PII — only for a verified signed-in shopper ──
        if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
            res.summary = IdentityService.signInMessage();
            return res;
        }
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) {
            res.summary = 'No account found for that email — ask the shopper to confirm their email or sign in.';
            res.caseNumber = logSolvedService(r, null, res.summary);
            return res;
        }
        Order o = KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if (o == null) {
            res.summary = 'No orders found on this account yet.';
            res.caseNumber = logSolvedService(r, null, res.summary);
            return res;
        }

        res.found = true;
        res.orderNumber = KwitkoServiceUtil.displayOrderNumber(o);
        res.wooOrderId = o.Woo_Order_Id__c;
        FulfillmentTruthService.Snapshot truth = FulfillmentTruthService.forOrder(o);
        res.fulfillmentStatus = truth.effectiveStatus;
        res.orderStatus = o.Status;
        res.total = o.TotalAmount;
        res.orderedDate = o.EffectiveDate == null ? null : String.valueOf(o.EffectiveDate);
        res.canCancel = KwitkoServiceUtil.canCancel(o);
        res.canReturn = KwitkoServiceUtil.canReturn(o);

        List<String> items = new List<String>();
        for (OrderItem oi : [SELECT Quantity, Product2.Name FROM OrderItem WHERE OrderId = :o.Id]) {
            items.add((oi.Quantity == null ? 1 : oi.Quantity.intValue()) + '× ' + oi.Product2.Name);
        }
        res.itemsSummary = String.join(items, ', ');

        // Cancellation/status traceability — so the agent can truthfully answer "who cancelled it / why".
        Order full = [SELECT Cancelled_By__c, Cancellation_Reason__c, Cancellation_Source__c, Cancelled_Date__c, Status_Note__c, Tracking_Number__c, Woo_Order_Total__c
                      FROM Order WHERE Id = :o.Id LIMIT 1];
        // Customer-facing total = WooCommerce grand total (incl. shipping), not the product-only subtotal.
        if (full.Woo_Order_Total__c != null) res.total = full.Woo_Order_Total__c;
        res.cancelledBy = full.Cancelled_By__c;
        res.cancellationReason = full.Cancellation_Reason__c;
        res.cancelledDate = full.Cancelled_Date__c == null ? null : full.Cancelled_Date__c.format();
        res.statusNote = full.Status_Note__c;
        res.trackingNumber = truth.trackingNumber;
        res.carrier = truth.carrier;
        res.trackingUrl = truth.trackingUrl;
        res.statusSource = truth.statusSource;
        // full service picture: return lifecycle + open cases on this order
        for (ReturnOrder ro : [SELECT Status FROM ReturnOrder WHERE Order__c = :o.Id ORDER BY CreatedDate DESC LIMIT 1]) res.returnStatus = ro.Status;
        List<Case> openCases = [
            SELECT CaseNumber, Category__c, Subject, Status
            FROM Case
            WHERE Order__c = :o.Id AND IsClosed = false
            ORDER BY CreatedDate DESC
            LIMIT 3
        ];
        res.openCaseCount = openCases.size();
        res.openCaseSummary = summarizeOpenCases(openCases);

        // Refer to the order by the WooCommerce order number the customer actually sees on the
        // storefront (e.g. "#506"), not the internal Salesforce OrderNumber.
        String displayNo = KwitkoServiceUtil.displayOrderNumber(o);
        res.summary = 'Order ' + displayNo + ' — ' + res.fulfillmentStatus
            + (String.isBlank(res.itemsSummary) ? '' : (': ' + res.itemsSummary))
            + (res.total == null ? '' : (' (total $' + res.total.setScale(2) + ')'))
            + '. ' + (res.canReturn ? 'Eligible for return.' : (res.canCancel ? 'Can still be cancelled.' : 'No cancel/return available at this stage.'));
        if (res.fulfillmentStatus == 'Cancelled' || res.fulfillmentStatus == 'Refunded'
                || res.fulfillmentStatus == 'Returned' || res.fulfillmentStatus == 'Return Pending') {
            res.summary += String.isNotBlank(full.Status_Note__c)
                ? (' ' + full.Status_Note__c)
                : (' ' + res.fulfillmentStatus + (String.isBlank(full.Cancellation_Reason__c) ? '' : ('; reason: ' + full.Cancellation_Reason__c))
                   + (String.isBlank(full.Cancelled_By__c) ? ' (who/when not recorded — predates traceability)' : ('; by ' + full.Cancelled_By__c)));
        }
        if (String.isNotBlank(res.returnStatus)) res.summary += ' Return status: ' + res.returnStatus + '.';
        if (String.isNotBlank(res.trackingNumber)) {
            res.summary += ' Tracking: ' + (String.isBlank(res.carrier) ? '' : res.carrier + ' ') + res.trackingNumber
                + (String.isBlank(res.trackingUrl) ? '' : ' ' + res.trackingUrl) + '.';
        }
        if (res.fulfillmentStatus == 'Shipped' && truth.hasDeliveryProof != true) {
            res.summary += ' This means it has shipped/been fulfilled; it is not marked delivered yet.';
        }
        if (String.isNotBlank(res.openCaseSummary)) res.summary += ' Open support case(s): ' + res.openCaseSummary + '.';
        res.caseNumber = logSolvedService(r, o.Id, res.summary);
        return res;
    }

    private static String summarizeOpenCases(List<Case> cases) {
        if (cases == null || cases.isEmpty()) return null;
        List<String> bits = new List<String>();
        for (Case c : cases) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(c.Category__c)) parts.add(c.Category__c);
            if (String.isNotBlank(c.Status)) parts.add(c.Status);
            String label = c.CaseNumber + (parts.isEmpty() ? '' : ' (' + String.join(parts, ', ') + ')');
            if (String.isNotBlank(c.Subject)) label += ': ' + truncate(c.Subject, 80);
            bits.add(label);
        }
        return String.join(bits, '; ');
    }

    private static String logSolvedService(Request r, Id orderId, String result) {
        Id interactionId = null;
        try {
            interactionId = JourneyService.recordInteractionOnly(
                r.email,
                'Service',
                'get_order_status',
                null,
                orderId == null ? null : String.valueOf(orderId),
                result,
                'Resolved',
                null,
                null
            );
        } catch (Exception e) {
            System.debug('journey log failed: ' + e.getMessage());
        }
        String caseNumber = createSolvedCase(r, orderId, result, interactionId);
        if (interactionId != null && String.isNotBlank(caseNumber)) {
            try {
                update new Agent_Interaction__c(
                    Id = interactionId,
                    Result__c = result + ' Case ' + caseNumber + ' created.'
                );
            } catch (Exception e) {
                System.debug('journey log case stamp failed: ' + e.getMessage());
            }
        }
        return caseNumber;
    }

    private static String createSolvedCase(Request r, Id orderId, String result, Id interactionId) {
        try {
            Account acc = KwitkoServiceUtil.findAccount(r.email);
            Order ord = null;
            if (orderId != null) {
                for (Order o : [SELECT Id, Woo_Order_Id__c FROM Order WHERE Id = :orderId LIMIT 1]) ord = o;
            }
            String transcript = String.isBlank(r.chatSummary)
                ? 'Transcript not provided by agent action.'
                : CaseTranscriptUtil.sanitizePreActionCaseClaims(r.chatSummary);
            String resolution = truncate(String.isBlank(result) ? 'Service interaction completed in chat.' : result.trim(), 4000);
            String description = truncate('--- Service resolution ---\n' + resolution
                + '\n\n--- Chat transcript ---\n' + transcript, 32000);
            Case c = new Case(
                AccountId = acc == null ? null : acc.Id,
                ContactId = acc == null ? null : acc.PersonContactId,
                SuppliedEmail = String.isBlank(r.email) ? null : r.email.trim(),
                Order__c = orderId,
                Origin = 'Chat',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = 'Order',
                Subject = 'Chat service: Order status answered',
                Summary__c = resolution,
                Description = description,
                Resolution__c = resolution,
                Resolved_By__c = 'Chat Agent (' + UserInfo.getName() + ')',
                Service_Interaction_Id__c = interactionId == null ? null : String.valueOf(interactionId)
            );
            if (ord != null) c.Woo_Order_Id__c = ord.Woo_Order_Id__c;
            insert c;
            Case created = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1];
            CaseTranscriptUtil.insertTaskWithResolution(c.Id, acc == null ? null : acc.PersonContactId, resolution, transcript);
            if (acc != null) {
                DataCloudAugmentationService.refreshAccount(acc.Id);
                DataCloudAugmentationService.refreshAccountFromDataCloudAsync(acc.Id);
            }
            return created.CaseNumber;
        } catch (Exception e) {
            System.debug('order status case creation failed: ' + e.getMessage());
            return null;
        }
    }

    private static String truncate(String value, Integer maxLen) {
        if (value == null || maxLen == null || maxLen <= 0) return value;
        return value.length() > maxLen ? value.substring(0, maxLen) : value;
    }
}
