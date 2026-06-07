/**
 * AbandonedCartSweep — the timer that turns a captured live cart into an abandoned-cart Lead.
 * Runs as a PRIVILEGED scheduled user (admin). Finds Active carts with a known email that have
 * been inactive >= 1 hour and have NO order since the last activity, and flips them to Abandoned.
 * That update fires the existing record-triggered Flow (Abandoned_Cart_to_Lead) -> AbandonedCartService
 * -> Lead -> CartRecoverySweep sends the recovery offer. Carts that DID convert are marked Converted.
 *
 * Schedule (every 15 min): System.schedule('Kwitko Cart Abandon Sweep NN','0 NN * * * ?', new AbandonedCartSweep());
 */
public without sharing class AbandonedCartSweep implements Schedulable {

    private static final Integer INACTIVITY_MINUTES = 60;

    public void execute(SchedulableContext sc) { run(); }

    public static Integer run() {
        Datetime cutoff = System.now().addMinutes(-INACTIVITY_MINUTES);
        List<Cart__c> carts = [
            SELECT Id, Shopper_Email__c, Last_Activity__c
            FROM Cart__c
            WHERE Status__c = 'Active' AND Shopper_Email__c != null AND Last_Activity__c <= :cutoff
            LIMIT 200];
        if (carts.isEmpty()) return 0;

        // did any of these shoppers place an order recently? -> mark Converted, not Abandoned
        Set<String> emails = new Set<String>();
        for (Cart__c c : carts) emails.add(c.Shopper_Email__c);
        Map<String, Datetime> lastOrderByEmail = new Map<String, Datetime>();
        for (Order o : [SELECT Account.PersonEmail, CreatedDate FROM Order
                        WHERE Account.PersonEmail IN :emails AND CreatedDate = LAST_N_DAYS:2
                        ORDER BY CreatedDate ASC]) {
            if (o.Account != null && o.Account.PersonEmail != null) lastOrderByEmail.put(o.Account.PersonEmail, o.CreatedDate);
        }

        List<Cart__c> toUpdate = new List<Cart__c>();
        for (Cart__c c : carts) {
            Datetime ord = lastOrderByEmail.get(c.Shopper_Email__c);
            if (ord != null && ord >= c.Last_Activity__c) {
                toUpdate.add(new Cart__c(Id = c.Id, Status__c = 'Converted'));
            } else {
                toUpdate.add(new Cart__c(Id = c.Id, Status__c = 'Abandoned', Abandoned_At__c = System.now()));
            }
        }
        update toUpdate; // Abandoned updates fire the Abandoned_Cart_to_Lead flow
        return toUpdate.size();
    }
}
