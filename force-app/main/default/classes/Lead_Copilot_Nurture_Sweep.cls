/**
 * Lead_Copilot_Nurture_Sweep — the autonomous trigger for the Lead Copilot.
 *
 * Runs daily as a privileged scheduled user. Finds leads that have been in Nurture status for
 * 30+ days and have not yet had a nurture step run, then enqueues the profile-driven nurture
 * step (LeadCopilotService.runNurtureStep) for each. Idempotent: Nurture_Last_Run__c is stamped
 * by the step, so each lead is acted on once per nurture cycle (re-arm by clearing the field).
 *
 * Schedule: System.schedule('Lead Copilot Nurture', '0 0 8 * * ?', new Lead_Copilot_Nurture_Sweep());
 */
public without sharing class Lead_Copilot_Nurture_Sweep implements Schedulable {

    /** Days a lead must sit in Nurture before the Copilot acts. */
    public static final Integer NURTURE_AGE_DAYS = 30;
    /** Days a 'Working - Contacted' lead can go without converting before it's handed to Nurture. */
    public static final Integer HANDOFF_AFTER_DAYS = 7;

    public void execute(SchedulableContext sc) {
        handoffStaleContacted();   // Inside Sales tried & couldn't convert -> Nurture
        sweep();                   // 30+ days in Nurture -> autonomous Copilot step
    }

    /**
     * Autonomous handoff: leads Inside Sales contacted but couldn't convert within HANDOFF_AFTER_DAYS
     * move into the Nurture track (stamping Nurture_Since__c) so the Copilot can take over.
     */
    public static Integer handoffStaleContacted() {
        Datetime cutoff = Datetime.now().addDays(-HANDOFF_AFTER_DAYS);
        Set<Id> ids = new Set<Id>();
        for (Lead l : [
            SELECT Id FROM Lead
            WHERE Status = 'Working - Contacted'
              AND IsConverted = false
              AND Purchase_Closed__c = false
              AND CreatedDate <= :cutoff
            LIMIT 200
        ]) ids.add(l.Id);
        return LeadCopilotService.markNurture(ids);
    }

    public static Integer sweep() {
        Date cutoff = Date.today().addDays(-NURTURE_AGE_DAYS);
        List<Lead> leads = [
            SELECT Id FROM Lead
            WHERE Status = :LeadCopilotService.STATUS_NURTURE
              AND IsConverted = false
              AND Nurture_Since__c != null
              AND Nurture_Since__c <= :cutoff
              AND Nurture_Last_Run__c = null
              AND Email != null
              AND Email_Consent__c = true
            LIMIT 100
        ];
        for (Lead l : leads) System.enqueueJob(new Job(l.Id));
        return leads.size();
    }

    public class Job implements Queueable, Database.AllowsCallouts {
        private Id leadId;
        public Job(Id leadId) { this.leadId = leadId; }
        public void execute(QueueableContext ctx) {
            LeadCopilotService.runNurtureStep(leadId);
        }
    }
}
