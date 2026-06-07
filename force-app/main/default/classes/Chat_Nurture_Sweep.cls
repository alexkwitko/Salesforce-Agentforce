/**
 * Chat_Nurture_Sweep — Flow 4: chat ended without a purchase.
 * Runs as a privileged scheduled user; finds consenting Website Chat leads that haven't purchased
 * (not closed) and enqueues a nurture offer for each. Source-agnostic lifecycle: purchase closes
 * the lead (LeadLifecycleService), so closed leads are skipped here.
 */
public without sharing class Chat_Nurture_Sweep implements Schedulable {
    public void execute(SchedulableContext sc) { sweep(); }
    public static Integer sweep() {
        List<Lead> leads = [
            SELECT Id FROM Lead
            WHERE Email_Consent__c = true AND IsConverted = false AND Purchase_Closed__c = false
              AND Status = 'Open - Not Contacted' AND LeadSource = 'Website Chat'
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
