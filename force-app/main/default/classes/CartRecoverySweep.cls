/**
 * CartRecoverySweep — headless cart-recovery. Runs as a privileged user (scheduled),
 * finds consenting abandoned-cart leads not yet contacted, and enqueues the recovery
 * offer for each. Idempotent: LeadNurtureService marks the lead 'Working - Contacted'.
 */
public without sharing class CartRecoverySweep implements Schedulable {
    public void execute(SchedulableContext sc) { sweep(); }
    public static Integer sweep() {
        List<Lead> leads = [
            SELECT Id FROM Lead
            WHERE Email_Consent__c = true AND IsConverted = false
              AND Status = 'Open - Not Contacted' AND LeadSource = 'WooCommerce Abandoned Cart'
              AND Email != null AND CreatedDate = LAST_N_DAYS:7
            LIMIT 50
        ];
        for (Lead l : leads) System.enqueueJob(new Job(l.Id));
        return leads.size();
    }
    public class Job implements Queueable, Database.AllowsCallouts {
        private Id leadId;
        public Job(Id leadId) { this.leadId = leadId; }
        public void execute(QueueableContext ctx) { LeadNurtureService.run(leadId); }
    }
}
