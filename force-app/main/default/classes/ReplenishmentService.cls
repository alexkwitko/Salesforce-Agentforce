/**
 * ReplenishmentService — "due to reorder" revenue automation (plan §4.1).
 * Daily: find consented buyers whose days-since-last-order has reached their
 * personal avg reorder cadence (from CustomerInsightsService) and send ONE
 * personalized, taste-aware "time to restock" email via the consent-gated
 * EmailService. Dedup so a customer isn't emailed again within one cadence window.
 */
public with sharing class ReplenishmentService implements Schedulable {
    private static final Integer BATCH_CAP = 200;

    public void execute(SchedulableContext sc) { run(); }

    public static String run() {
        Date today = Date.today();
        List<EmailService.Request> sends = new List<EmailService.Request>();
        List<Account> stamp = new List<Account>();
        for (Account a : [SELECT Id, FirstName, PersonEmail, Insights_Taste_Profile__c,
                                 Insights_Avg_Days_Between_Orders__c, Insights_Days_Since_Last_Order__c,
                                 Insights_Last_Replenish_Email__c
                          FROM Account
                          WHERE Email_Consent__c = true AND PersonEmail != null
                            AND Insights_Avg_Days_Between_Orders__c > 0
                            AND Insights_Days_Since_Last_Order__c != null
                          LIMIT :BATCH_CAP]) {
            Decimal cadence = a.Insights_Avg_Days_Between_Orders__c;
            if (a.Insights_Days_Since_Last_Order__c < cadence) continue;           // not due yet
            if (a.Insights_Last_Replenish_Email__c != null
                && a.Insights_Last_Replenish_Email__c.daysBetween(today) < cadence) continue; // already nudged this cycle
            EmailService.Request r = new EmailService.Request();
            r.toEmail = a.PersonEmail;
            r.subject = 'Running low? Time to restock your Kwitko coffee';
            r.htmlBody = body(a);
            r.recordId = a.Id;          // EmailService re-checks consent on this record
            r.isTransactional = false;  // marketing → consent-gated
            sends.add(r);
            stamp.add(new Account(Id = a.Id, Insights_Last_Replenish_Email__c = today));
        }
        if (!sends.isEmpty()) EmailService.send(sends);
        if (!stamp.isEmpty()) update stamp;
        return 'ReplenishmentService: ' + sends.size() + ' due-to-reorder email(s) queued.';
    }

    @TestVisible static String body(Account a) {
        String name = String.isNotBlank(a.FirstName) ? a.FirstName : 'there';
        String fav = favorite(a.Insights_Taste_Profile__c);
        return '<p>Hi ' + name + ',</p>'
            + '<p>Going by your usual rhythm, you\'re about due for a refill'
            + (fav != null ? (' of your go-to <strong>' + fav + '</strong>') : ' of your favorites') + '.</p>'
            + '<p>Reorder in a tap: <a href="https://deepskyblue-deer-920559.hostingersite.com/shop/">the Kwitko shop</a>.</p>'
            + '<p>— Kwitko Coffee Co.</p>';
    }
    @TestVisible static String favorite(String taste) {
        if (String.isBlank(taste)) return null;
        Matcher m = Pattern.compile('Roast:\\s*([^()|]+)').matcher(taste);
        return m.find() ? (m.group(1).trim() + ' roast') : null;
    }

    /** Daily at 09:00. Idempotent. */
    public static String scheduleDaily() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'Replenishment-Daily'])
            System.abortJob(ct.Id);
        return System.schedule('Replenishment-Daily', '0 0 9 * * ?', new ReplenishmentService());
    }
}
