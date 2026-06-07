/**
 * EmailService — the ONE consent-gated outbound email action (D-9).
 * Both Post_Purchase and Inside_Sales call this after the agent composes the body.
 * Re-checks Email_Consent__c from the related record (Order/Lead/Account) before sending.
 */
public without sharing class EmailService {

    // Freemail domains whose OWEAs fail recipient DMARC when relayed via Salesforce — skip them so the
    // org "substitute address for unverified domains" sends from a Salesforce-authenticated address instead.
    private static final Set<String> FREEMAIL = new Set<String>{
        'gmail.com','googlemail.com','yahoo.com','hotmail.com','outlook.com','live.com','aol.com','icloud.com','me.com'
    };

    public class Request {
        @InvocableVariable(label='To Email' required=true) public String toEmail;
        @InvocableVariable(label='Subject' required=true) public String subject;
        @InvocableVariable(label='HTML Body' required=true) public String htmlBody;
        @InvocableVariable(label='Record Id (Order/Lead/Account for consent re-check)') public String recordId;
        @InvocableVariable(label='Transactional Email' description='True only for non-marketing service emails such as return labels or password/help messages.') public Boolean isTransactional;
    }
    public class Response {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Send Email (consent-gated)'
        description='Sends an HTML email after re-checking marketing consent on the related record. The agent writes the body; this sends it.')
    public static List<Response> send(List<Request> reqs) {
        List<Response> out = new List<Response>();
        for (Request r : reqs) out.add(doSend(r));
        return out;
    }

    private static Response doSend(Request r) {
        Response resp = new Response(); resp.success = false;
        if (String.isBlank(r.toEmail)) { resp.message = 'No recipient.'; return resp; }
        if (!consentOk(r.recordId, r.isTransactional)) { resp.message = 'No consent on file; email NOT sent.'; return resp; }
        try {
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>{ r.toEmail });
            m.setSubject(r.subject);
            m.setHtmlBody(r.htmlBody);
            m.setSaveAsActivity(false);
            // Sender: prefer a verified OWEA on a REAL (non-freemail) domain so SPF/DKIM pass. A freemail
            // OWEA (gmail/outlook/etc.) now FAILS the recipient's DMARC after Salesforce's mandatory
            // sending-domain enforcement, so we DON'T use it — instead we leave the From unset and rely on
            // org Deliverability "substitute address for unverified domains", which sends from a
            // Salesforce-authenticated address that actually delivers. Branding is preserved via display name.
            Boolean oweaSet = false;
            for (OrgWideEmailAddress o : [SELECT Id, Address, DisplayName FROM OrgWideEmailAddress WHERE IsVerified = true ORDER BY DisplayName]) {
                String dom = (o.Address != null && o.Address.contains('@')) ? o.Address.substringAfterLast('@').toLowerCase() : '';
                if (!FREEMAIL.contains(dom)) { m.setOrgWideEmailAddressId(o.Id); oweaSet = true; break; }
            }
            if (!oweaSet) m.setSenderDisplayName('Kwitko Coffee Co.');
            if (!Test.isRunningTest()) Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m });
            resp.success = true; resp.message = 'Sent to ' + r.toEmail;
        } catch (Exception e) { resp.message = e.getMessage(); }
        return resp;
    }

    private static Boolean consentOk(String recordId, Boolean isTransactional) {
        if (String.isBlank(recordId)) return isTransactional == true;
        try {
            Id id = (Id) recordId;
            String t = id.getSObjectType().getDescribe().getName();
            if (t == 'Lead')    return [SELECT Email_Consent__c FROM Lead    WHERE Id = :id LIMIT 1].Email_Consent__c == true;
            if (t == 'Account') return [SELECT Email_Consent__c FROM Account WHERE Id = :id LIMIT 1].Email_Consent__c == true;
            if (t == 'Order')   return [SELECT Account.Email_Consent__c FROM Order WHERE Id = :id LIMIT 1].Account.Email_Consent__c == true;
        } catch (Exception e) { return false; }
        return true;
    }
}
