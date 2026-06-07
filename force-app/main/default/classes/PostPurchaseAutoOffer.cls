/**
 * PostPurchaseAutoOffer — the HEADLESS entry point.
 * Called by the record-triggered Flow "Auto Post-Purchase Offer" when an
 * e-commerce Order is activated. It enqueues an async job so the WooCommerce
 * callout + email run safely outside the trigger transaction. No human, no chat.
 * (A class can have only one @InvocableMethod, so this is separate from
 *  PostPurchaseService, which the assisted agent calls.)
 */
public with sharing class PostPurchaseAutoOffer {

    public class Request {
        @InvocableVariable(label='Order ID' required=true) public Id orderId;
    }

    @InvocableMethod(label='Auto-Generate Post-Purchase Offer'
        description='Headless: enqueues the post-purchase offer (recommend + coupon + email) for an order. Consent is enforced inside the job.')
    public static void run(List<Request> requests) {
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) if (r.orderId != null) ids.add(r.orderId);
        for (Id oid : ids) System.enqueueJob(new Job(oid));
    }

    public class Job implements Queueable, Database.AllowsCallouts {
        private Id orderId;
        public Job(Id orderId) { this.orderId = orderId; }
        public void execute(QueueableContext ctx) {
            PostPurchaseService.buildOffer(orderId);
        }
    }
}
