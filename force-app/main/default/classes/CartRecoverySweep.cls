/**
 * CartRecoverySweep — headless cart-recovery, CART-CENTRIC.
 * Finds ABANDONED carts with consent that have a linked Lead and have NOT yet been
 * recovered, dedupes by lead, and enqueues the recovery offer. This works whether the
 * cart attached to a brand-new lead OR a pre-existing (e.g. chat) lead — the old
 * lead-source/status filter silently missed the pre-existing-lead case. Idempotent:
 * stamps Cart__c.Recovery_Sent_At__c and LeadNurtureService marks the lead Working-Contacted.
 */
public without sharing class CartRecoverySweep implements Schedulable {
    public void execute(SchedulableContext sc) { sweep(); }

    public static Integer sweep() {
        List<Cart__c> carts = [
            SELECT Id, Lead__c FROM Cart__c
            WHERE Status__c = 'Abandoned'
              AND Email_Consent__c = true
              AND Lead__c != null
              AND Recovery_Sent_At__c = null
              AND LastModifiedDate = LAST_N_DAYS:7
            LIMIT 100
        ];
        Set<Id> leadIds = new Set<Id>();
        List<Cart__c> stamp = new List<Cart__c>();
        for (Cart__c c : carts) {
            leadIds.add(c.Lead__c);
            stamp.add(new Cart__c(Id = c.Id, Recovery_Sent_At__c = System.now()));
        }
        for (Id lid : leadIds) System.enqueueJob(new Job(lid));
        if (!stamp.isEmpty()) update stamp;
        return leadIds.size();
    }

    public class Job implements Queueable, Database.AllowsCallouts {
        private Id leadId;
        public Job(Id leadId) { this.leadId = leadId; }
        public void execute(QueueableContext ctx) { LeadNurtureService.run(leadId); }
    }
}
