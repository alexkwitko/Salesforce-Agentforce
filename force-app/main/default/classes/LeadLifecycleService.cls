/**
 * LeadLifecycleService — purchase closes the lead cycle, source-agnostic.
 * The order path creates/updates the Person Account first. We then attempt native Salesforce
 * lead conversion into that account so standard ConvertedAccount/Contact fields are populated.
 * If native conversion cannot run in a specific org context, we fall back to the custom
 * purchase-close fields so nurture still stops and attribution remains traceable.
 */
public without sharing class LeadLifecycleService {

    /** Close every open Lead for this email (any source) as Converted-by-purchase. */
    public static void closeForPurchase(String email, Id accountId, Id orderId) {
        if (String.isBlank(email)) return;
        List<Lead> open = [
            SELECT Id, Status, Purchase_Closed__c, Converted_Account__c, Converted_Order__c, Closed_Date__c
            FROM Lead
            WHERE Email = :email AND IsConverted = false];
        if (open.isEmpty()) return;
        String convertedStatus = convertedStatus();
        for (Lead l : open) {
            l.Purchase_Closed__c = true;
            l.Converted_Account__c = accountId;
            l.Converted_Order__c = orderId;
            l.Closed_Date__c = System.now();
        }
        update open;
        convertNative(open, accountId, convertedStatus);
        // reflect on the journey
        Customer_Journey__c j = JourneyService.getOrCreate(email, accountId, null);
        if (j != null) { j.Last_Stage__c = 'Purchased'; update j; }
    }

    // Invocable wrapper (so Flows can call it too)
    public class Request {
        @InvocableVariable(required=true) public String email;
        @InvocableVariable public String accountId;
        @InvocableVariable public String orderId;
    }
    @InvocableMethod(label='Close Leads For Purchase'
        description='Closes all open leads for an email (any source) as converted-by-purchase and links the account/order.')
    public static void closeForPurchaseInvocable(List<Request> reqs) {
        for (Request r : reqs) {
            Id acc = String.isBlank(r.accountId) ? null : (Id) r.accountId;
            Id ord = String.isBlank(r.orderId) ? null : (Id) r.orderId;
            closeForPurchase(r.email, acc, ord);
        }
    }

    private static String convertedStatus() {
        List<LeadStatus> statuses = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
        return statuses.isEmpty() ? 'Closed - Converted' : statuses[0].MasterLabel;
    }

    private static void convertNative(List<Lead> leads, Id accountId, String convertedStatus) {
        if (accountId == null || String.isBlank(convertedStatus)) return;
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
        for (Lead l : leads) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(l.Id);
            lc.setAccountId(accountId);
            lc.setConvertedStatus(convertedStatus);
            lc.setDoNotCreateOpportunity(true);
            converts.add(lc);
        }
        try {
            List<Database.LeadConvertResult> results = Database.convertLead(converts, false);
            List<Lead> fallback = new List<Lead>();
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    fallback.add(new Lead(Id = leads[i].Id, Status = convertedStatus));
                }
            }
            if (!fallback.isEmpty()) update fallback;
        } catch (Exception e) {
            List<Lead> fallback = new List<Lead>();
            for (Lead l : leads) fallback.add(new Lead(Id = l.Id, Status = convertedStatus));
            if (!fallback.isEmpty()) update fallback;
        }
    }
}
