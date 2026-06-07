/**
 * PostPurchaseSweep — the reliable HEADLESS trigger for the post-purchase offer.
 * The WooCommerce webhook runs as the locked-down Site guest user, which can't
 * safely run the privileged offer (credential callout / coupon create / email).
 * So instead this Schedulable runs as a proper privileged user (whoever schedules
 * it, e.g. an admin/integration user), finds newly-ingested e-commerce orders that
 * are consented and have no offer yet, and enqueues the offer for each.
 * Idempotent (buildOffer skips orders that already have a coupon).
 */
public without sharing class PostPurchaseSweep implements Schedulable {

    public void execute(SchedulableContext sc) { sweep(); }

    /** Returns how many orders were picked up. */
    public static Integer sweep() {
        // "Already offered" = the order already has a post-purchase Coupon__c — NOT Coupon_Code__c.
        // Ingestion writes the customer's REDEEMED checkout coupon into Coupon_Code__c, so guarding on
        // it wrongly skipped every order that used a coupon at checkout (e.g. Woo #212).
        List<Order> orders = [
            SELECT Id FROM Order
            WHERE Source__c = 'Ecommerce' AND Status = 'Activated'
              AND Account.Email_Consent__c = true
              AND CreatedDate = LAST_N_DAYS:3
              AND Id NOT IN (SELECT Order__c FROM Coupon__c WHERE Order__c != null)
            LIMIT 50
        ];
        for (Order o : orders) System.enqueueJob(new PostPurchaseAutoOffer.Job(o.Id));
        return orders.size();
    }
}
