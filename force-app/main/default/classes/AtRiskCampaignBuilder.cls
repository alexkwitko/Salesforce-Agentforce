/**
 * AtRiskCampaignBuilder — the Data Cloud "segment -> activation" stand-in using
 * Classic CRM Campaigns. Selects high-value, high-churn-risk, consented customers
 * and adds them as CampaignMembers on the win-back Campaign. Tier-A (top value-at-
 * risk) also get a follow-up Task for a human. Idempotent (no duplicate members).
 */
public with sharing class AtRiskCampaignBuilder {

    public static final String  CAMPAIGN_NAME = 'DC - High-Value At-Risk Win-Back';
    public static final Decimal CHURN_MIN = 0.70;
    public static final Decimal LTV_MIN   = 200;

    public static Id ensureCampaign() {
        List<Campaign> ex = [SELECT Id FROM Campaign WHERE Name = :CAMPAIGN_NAME LIMIT 1];
        if (!ex.isEmpty()) return ex[0].Id;
        Campaign c = new Campaign(
            Name = CAMPAIGN_NAME, Type = 'Email', Status = 'In Progress', IsActive = true,
            Description = 'Data Cloud predictive: high-value, high-churn-risk customers for win-back.');
        insert c;
        return c.Id;
    }

    public static Integer run() {
        Id campId = ensureCampaign();

        Set<Id> existing = new Set<Id>();
        for (CampaignMember cm : [SELECT ContactId FROM CampaignMember
                                  WHERE CampaignId = :campId AND ContactId != null]) {
            existing.add(cm.ContactId);
        }

        List<CampaignMember> toAdd = new List<CampaignMember>();
        List<Task> tasks = new List<Task>();
        for (Account a : [
                SELECT Id, PersonContactId, Churn_Score__c, Predicted_LTV__c,
                       Value_At_Risk__c, Churn_Risk_Tier__c
                FROM Account
                WHERE IsPersonAccount = true AND PersonContactId != null
                  AND Email_Consent__c = true
                  AND Churn_Score__c >= :CHURN_MIN
                  AND Predicted_LTV__c >= :LTV_MIN ]) {
            if (existing.contains(a.PersonContactId)) continue;
            toAdd.add(new CampaignMember(CampaignId = campId, ContactId = a.PersonContactId));
            if (a.Churn_Risk_Tier__c == 'A') {
                tasks.add(new Task(
                    Subject = 'High-value at-risk - personal win-back follow-up',
                    WhoId = a.PersonContactId, Priority = 'High', Status = 'Not Started',
                    ActivityDate = Date.today().addDays(2),
                    Description = 'Value at risk: ' + a.Value_At_Risk__c + '. Personal outreach + richest offer.'));
            }
        }
        if (!toAdd.isEmpty()) insert toAdd;
        if (!tasks.isEmpty()) insert tasks;
        return toAdd.size();
    }

    /** Activation: send the win-back email to members not yet emailed. Consent re-checked
     *  by EmailService against the Account; idempotent via the 'Emailed' member status. */
    public static Integer sendWinBack() {
        Id campId = ensureCampaign();
        ensureEmailedStatus(campId);

        List<CampaignMember> pending = [
            SELECT Id, ContactId, Contact.FirstName, Contact.Email, Contact.AccountId,
                   Contact.Account.Churn_Risk_Tier__c, Contact.Account.Web_Last_Seen__c
            FROM CampaignMember
            WHERE CampaignId = :campId AND Status != 'Emailed'
              AND Contact.Email != null LIMIT 50 ];
        if (pending.isEmpty()) return 0;

        List<EmailService.Request> reqs = new List<EmailService.Request>();
        for (CampaignMember cm : pending) {
            String first = String.isBlank(cm.Contact.FirstName) ? 'there' : cm.Contact.FirstName;
            Boolean browsedRecently = cm.Contact.Account.Web_Last_Seen__c != null
                && cm.Contact.Account.Web_Last_Seen__c >= System.now().addDays(-14);
            EmailService.Request r = new EmailService.Request();
            r.toEmail = cm.Contact.Email;
            r.recordId = cm.Contact.AccountId;
            r.isTransactional = false;
            r.subject = 'We miss you at Kwitko Coffee, ' + first;
            r.htmlBody = '<p>Hi ' + first + ',</p>'
                + '<p>It’s been a while since your last order, and good coffee shouldn’t wait.'
                + (browsedRecently
                    ? ' We noticed you’ve been browsing — if something caught your eye, now’s a great moment.'
                    : ' We’ve added new roasts since your last visit that we think you’ll love.')
                + '</p>'
                + '<p>Stop by the shop, or open the chat on our site — our concierge can put together '
                + 'a personal offer for returning customers like you.</p>'
                + '<p><a href="https://deepskyblue-deer-920559.hostingersite.com/">Browse the latest roasts →</a></p>'
                + '<p>— Kwitko Coffee Co.</p>';
            reqs.add(r);
        }

        List<EmailService.Response> resps = EmailService.send(reqs);
        List<CampaignMember> mark = new List<CampaignMember>();
        Integer sent = 0;
        for (Integer i = 0; i < resps.size(); i++) {
            if (resps[i].success) {
                sent++;
                mark.add(new CampaignMember(Id = pending[i].Id, Status = 'Emailed'));
            }
        }
        if (!mark.isEmpty()) update mark;
        return sent;
    }

    private static void ensureEmailedStatus(Id campId) {
        if (![SELECT Id FROM CampaignMemberStatus WHERE CampaignId = :campId AND Label = 'Emailed'].isEmpty()) return;
        insert new CampaignMemberStatus(CampaignId = campId, Label = 'Emailed', SortOrder = 4, HasResponded = false);
    }

    public class Scheduler implements Schedulable {
        public void execute(SchedulableContext sc) {
            AtRiskCampaignBuilder.run();
            AtRiskCampaignBuilder.sendWinBack();
        }
    }
}
