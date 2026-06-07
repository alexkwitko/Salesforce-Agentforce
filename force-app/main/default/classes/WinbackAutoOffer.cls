/**
 * WinbackAutoOffer — headless entry point invoked by the record-triggered Flow "Winback On Return"
 * when an Account is flagged Winback_Needed__c=true. Enqueues an async job so the WooCommerce coupon
 * callout + email run outside the trigger transaction.
 */
public with sharing class WinbackAutoOffer {
    public class Request {
        @InvocableVariable(label='Account ID' required=true) public Id accountId;
    }
    @InvocableMethod(label='Auto Win-Back Offer'
        description='Headless: enqueues a confidence-rebuild offer (recommend + coupon + apology email) for a customer who just returned an order.')
    public static void run(List<Request> requests) {
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) if (r.accountId != null) ids.add(r.accountId);
        for (Id aid : ids) System.enqueueJob(new Job(aid));
    }
    public class Job implements Queueable, Database.AllowsCallouts {
        private Id accountId;
        public Job(Id accountId) { this.accountId = accountId; }
        public void execute(QueueableContext ctx) { WinbackService.sendWinback(accountId); }
    }
}
