/**
 * ChatLeadService — capture a Lead from the website chat (name, email, consent, interest, prefs).
 * Upserts by email (LeadSource = 'Website Chat'); links a Customer_Journey__c. Consent captured
 * explicitly in chat before any marketing.
 */
public without sharing class ChatLeadService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='First Name') public String firstName;
        @InvocableVariable(label='Last Name') public String lastName;
        @InvocableVariable(label='Marketing Consent') public Boolean consent;
        @InvocableVariable(label='Interest') public String interest;
        @InvocableVariable(label='Chat Summary') public String chatSummary;
        @InvocableVariable(label='Preferences JSON') public String preferencesJson;
    }
    public class Result {
        @InvocableVariable public String leadId;
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Capture Chat Lead'
        description='Creates/updates a Lead from the website chat (LeadSource Website Chat) with consent + interest + preferences, and links the customer journey.')
    public static List<Result> capture(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doCapture(r));
        return out;
    }

    private static Result doCapture(Request r) {
        Result res = new Result(); res.success = false;
        if (String.isBlank(r.email)) { res.message = 'Email required.'; return res; }
        String last = String.isBlank(r.lastName) ? (String.isBlank(r.firstName) ? 'Shopper' : r.firstName) : r.lastName;

        List<Lead> existing = [SELECT Id, Email_Consent__c, Chat_Summary__c FROM Lead
                               WHERE Email = :r.email AND IsConverted = false AND Purchase_Closed__c = false LIMIT 1];
        Lead l = existing.isEmpty()
            ? new Lead(LastName = last, Company = 'Consumer', Email = r.email, LeadSource = 'Website Chat',
                       Status = 'Open - Not Contacted')
            : existing[0];
        if (String.isNotBlank(r.firstName)) l.FirstName = r.firstName;
        if (existing.isEmpty()) l.LastName = last;
        if (r.consent == true) l.Email_Consent__c = true;        // never auto-revoke
        if (String.isNotBlank(r.interest)) l.Chat_Interest__c = r.interest;
        // Transcript summary: prefer the agent's rich summary; otherwise derive a deterministic one so a
        // chat record is ALWAYS retained (native ConversationEntry isn't persisted in this org).
        if (String.isNotBlank(r.chatSummary)) {
            l.Chat_Summary__c = r.chatSummary.length() > 32000 ? r.chatSummary.substring(0, 32000) : r.chatSummary;
        } else if (String.isBlank(l.Chat_Summary__c)) {
            List<String> bits = new List<String>();
            bits.add('Website chat on ' + System.now().format());
            if (String.isNotBlank(r.interest)) bits.add('Interest: ' + r.interest);
            if (String.isNotBlank(r.preferencesJson)) bits.add('Preferences: ' + r.preferencesJson);
            if (r.consent == true) bits.add('Marketing consent: yes');
            l.Chat_Summary__c = String.join(bits, ' | ');
        }
        if (String.isNotBlank(r.preferencesJson)) l.Preferences__c = r.preferencesJson;
        upsert l;
        res.leadId = l.Id;

        // journey
        Customer_Journey__c j = JourneyService.getOrCreate(r.email, null, l.Id);
        if (j != null) {
            if (String.isNotBlank(r.preferencesJson)) j.Preferences__c = r.preferencesJson;
            j.Last_Stage__c = 'Browsing'; j.Last_Agent__c = 'Kwitko_Concierge'; j.Last_Interaction__c = System.now();
            update j;
        }
        // Transcript on the PERSON: if this email is a known customer (Person Account), log the chat
        // summary as a completed Task on their Contact so the conversation lives on the person, not only
        // on the Lead (native ConversationEntry isn't persisted; this gives agents/CSRs a durable trail).
        try {
            Account acc = KwitkoServiceUtil.findAccount(r.email);
            if (acc != null && acc.PersonContactId != null && String.isNotBlank(l.Chat_Summary__c)) {
                insert new Task(
                    WhoId = acc.PersonContactId,
                    Subject = 'Website chat',
                    Status = 'Completed',
                    Priority = 'Normal',
                    ActivityDate = Date.today(),
                    Type = 'Chat',
                    Description = l.Chat_Summary__c.length() > 32000 ? l.Chat_Summary__c.substring(0, 32000) : l.Chat_Summary__c
                );
            }
        } catch (Exception e) { System.debug('transcript->Contact task failed: ' + e.getMessage()); }

        res.success = true; res.message = 'Lead captured.';
        return res;
    }
}
