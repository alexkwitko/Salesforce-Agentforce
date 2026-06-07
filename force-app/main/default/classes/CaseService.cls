/**
 * CaseService — agent action to open/categorize a support Case on the shopper's Person Account
 * (optionally linked to an Order), and to escalate to a human. The Service subagent calls this for
 * complaints, "open a case", and out-of-scope requests.
 */
public without sharing class CaseService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Category' description='Order | Shipping | Returns | Refund | Product | Billing | Account | Escalation') public String category;
        @InvocableVariable(label='Subject' required=true) public String subject;
        @InvocableVariable(label='Description') public String description;
        @InvocableVariable(label='Order Identifier (Woo id / order number, optional)') public String orderIdentifier;
        @InvocableVariable(label='Priority (Low | Medium | High)') public String priority;
        @InvocableVariable(label='Escalate to a human agent') public Boolean escalate;
        @InvocableVariable(label='Chat Summary (a faithful detailed transcript or summary of the whole conversation so far)') public String chatSummary;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public String caseId;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Open Support Case'
        description='Creates a categorized support Case for the shopper (optionally linked to an order) and can escalate to a human. Returns the case number.')
    public static List<Result> open(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doOpen(r));
        return out;
    }

    private static Result doOpen(Request r) {
        Result res = new Result(); res.success = false;
        Account acc = KwitkoServiceUtil.findAccount(r.email);
        if (acc == null) { res.message = 'No account found for that email; ask the shopper to confirm their email or sign in.'; return res; }

        Order ord = String.isBlank(r.orderIdentifier) ? null : KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);

        String cat = normCategory(r.category);
        // Persist the chat transcript ON the case: standard Description carries the issue detail PLUS the
        // full conversation transcript (Description is a 32k long-text), so the case is self-contained and a
        // CSR sees what was said. (Native ConversationEntry is not persisted in this org — this is the trail.)
        String transcript = String.isBlank(r.chatSummary) ? '' : r.chatSummary.trim();
        String caseDescription = String.isBlank(r.description) ? '' : r.description.trim();
        if (String.isNotBlank(transcript)) {
            caseDescription = (String.isBlank(caseDescription) ? '' : (caseDescription + '\n\n'))
                + '--- Chat transcript ---\n' + transcript;
        }
        if (caseDescription.length() > 32000) caseDescription = caseDescription.substring(0, 32000);

        Case c = new Case(
            AccountId = acc.Id,
            ContactId = acc.PersonContactId,
            Subject = String.isBlank(r.subject) ? 'Chat request' : r.subject,
            Description = caseDescription,
            Origin = 'Chat',
            Status = (r.escalate == true) ? 'Escalated' : 'New',
            Priority = normPriority(r.priority, r.escalate == true),
            Category__c = cat,
            Summary__c = (String.isBlank(r.subject) ? '' : (r.subject + ' — ')) + (String.isBlank(r.description) ? 'Opened from chat.' : r.description)
                + (ord != null ? (' (order ' + ord.OrderNumber + ')') : '')
        );
        if (ord != null) { c.Order__c = ord.Id; c.Woo_Order_Id__c = ord.Woo_Order_Id__c; }
        if (r.escalate == true) {
            for (Group g : [SELECT Id FROM Group WHERE DeveloperName = 'Kwitko_Escalations' AND Type = 'Queue' LIMIT 1]) c.OwnerId = g.Id;
        }
        try {
            insert c;
            Case created = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1];
            res.success = true;
            res.caseId = c.Id;
            res.caseNumber = created.CaseNumber;
            // Chat transcript as a visible activity ON the case timeline (what a CSR opens the case to read).
            if (String.isNotBlank(transcript)) {
                try {
                    insert new Task(
                        WhatId = c.Id,
                        WhoId = acc.PersonContactId,
                        Subject = 'Chat transcript',
                        Status = 'Completed',
                        Priority = 'Normal',
                        ActivityDate = Date.today(),
                        Type = 'Chat',
                        Description = transcript.length() > 32000 ? transcript.substring(0, 32000) : transcript
                    );
                } catch (Exception tex) { System.debug('case transcript task failed: ' + tex.getMessage()); }
            }
            // Cross-agent context: log so any agent sees this case on the customer's journey.
            try {
                JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
                lr.email = acc.PersonEmail; lr.agent = 'Service';
                lr.action = (r.escalate == true) ? 'escalate_case' : 'open_case'; lr.stage = 'Service';
                lr.result = 'Case ' + created.CaseNumber + ' (' + cat + '): ' + (String.isBlank(r.subject) ? 'chat request' : r.subject);
                if (String.isNotBlank(acc.PersonEmail)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
            } catch (Exception ex) { System.debug('journey log failed: ' + ex.getMessage()); }
            res.message = (r.escalate == true)
                ? ('Escalated to our team — case ' + created.CaseNumber + '. A specialist will follow up.')
                : ('Opened case ' + created.CaseNumber + ' (' + cat + '). We\'re on it.');
        } catch (Exception e) {
            res.message = 'Could not open the case: ' + e.getMessage();
        }
        return res;
    }

    private static String normCategory(String c) {
        if (String.isBlank(c)) return 'Order';
        String t = c.trim().toLowerCase();
        if (t.contains('ship')) return 'Shipping';
        if (t.contains('return')) return 'Returns';
        if (t.contains('refund')) return 'Refund';
        if (t.contains('product')) return 'Product';
        if (t.contains('bill') || t.contains('pay')) return 'Billing';
        if (t.contains('account')) return 'Account';
        if (t.contains('escal')) return 'Escalation';
        return 'Order';
    }
    private static String normPriority(String p, Boolean escalated) {
        if (escalated) return 'High';
        if (String.isBlank(p)) return 'Medium';
        String t = p.trim().toLowerCase();
        if (t.startsWith('h')) return 'High';
        if (t.startsWith('l')) return 'Low';
        return 'Medium';
    }
}
