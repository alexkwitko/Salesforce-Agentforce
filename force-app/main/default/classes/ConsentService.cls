/**
 * ConsentService — lightweight, side-effect-free email-consent check.
 * Designed to be the FIRST action an agent runs (before any offer/recovery action),
 * and to be callable from orchestration Flows BEFORE an agent is ever invoked
 * (so non-consented customers never incur agent/LLM or action cost).
 * Accepts an Order, Lead, or Account record id.
 */
public with sharing class ConsentService {

    public class Request {
        @InvocableVariable(label='Record Id' description='Order, Lead, or Account record Id to check for email consent.' required=true)
        public Id recordId;
    }

    public class Result {
        @InvocableVariable(label='Has Consent') public Boolean hasConsent;
        @InvocableVariable(label='Message') public String message;
    }

    @InvocableMethod(label='Check Email Consent'
        description='Returns whether the customer or lead behind a record has granted email marketing consent. Call this FIRST, before any outreach action.')
    public static List<Result> check(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) out.add(run(r.recordId));
        return out;
    }

    public static Result run(Id recordId) {
        Result res = new Result();
        res.hasConsent = false;
        if (recordId == null) { res.message = 'No record Id provided.'; return res; }

        String sobj = recordId.getSObjectType().getDescribe().getName();
        if (sobj == 'Order') {
            Order o = [SELECT Account.Name, Account.Email_Consent__c FROM Order WHERE Id = :recordId LIMIT 1];
            res.hasConsent = (o.Account.Email_Consent__c == true);
            res.message = res.hasConsent
                ? 'Customer ' + o.Account.Name + ' has granted email consent — safe to proceed.'
                : 'Customer ' + o.Account.Name + ' has NOT granted email consent — STOP. Do not generate or send an offer.';
        } else if (sobj == 'Lead') {
            Lead l = [SELECT Name, Email_Consent__c FROM Lead WHERE Id = :recordId LIMIT 1];
            res.hasConsent = (l.Email_Consent__c == true);
            res.message = res.hasConsent
                ? 'Lead ' + l.Name + ' has granted email consent — safe to proceed.'
                : 'Lead ' + l.Name + ' has NOT granted email consent — STOP. Do not send a recovery offer.';
        } else if (sobj == 'Account') {
            Account a = [SELECT Name, Email_Consent__c FROM Account WHERE Id = :recordId LIMIT 1];
            res.hasConsent = (a.Email_Consent__c == true);
            res.message = res.hasConsent
                ? 'Customer ' + a.Name + ' has granted email consent — safe to proceed.'
                : 'Customer ' + a.Name + ' has NOT granted email consent — STOP.';
        } else {
            res.message = 'Unsupported record type for consent check: ' + sobj;
        }
        return res;
    }
}
