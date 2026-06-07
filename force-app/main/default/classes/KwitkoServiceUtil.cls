/**
 * KwitkoServiceUtil — shared lookups + lifecycle eligibility for the Service subagent actions.
 * Centralizes "find the customer's order" and the cancel/return eligibility matrix so every action
 * enforces the same rules (an order in transit can't be returned; a shipped order can't be cancelled).
 */
public without sharing class KwitkoServiceUtil {

    // Fulfillment lifecycle eligibility. Effective status comes from FulfillmentTruthService,
    // which prefers Shipment/FulfillmentOrder over the legacy Order field.
    public static final Set<String> CANCELLABLE = new Set<String>{ 'Not Shipped', 'Processing', null, '' };
    public static final Set<String> RETURNABLE  = new Set<String>{ 'Delivered' };

    public static Account findAccount(String email) {
        if (String.isBlank(email)) return null;
        List<Account> a = [SELECT Id, PersonContactId, FirstName, PersonEmail, Woo_Customer_Id__c,
                                  Return_Count__c
                           FROM Account WHERE PersonEmail = :email LIMIT 1];
        return a.isEmpty() ? null : a[0];
    }

    /**
     * Resolve a specific order for a customer. `identifier` may be a Salesforce Order Id, an
     * OrderNumber, or a WooCommerce order id; if blank, returns the customer's most recent order.
     * Always scoped to the account so a customer can only act on their own orders.
     */
    public static Order findOrder(Id accountId, String identifier) {
        if (accountId == null) return null;
        List<Order> found;
        String idf = identifier == null ? '' : identifier.trim();
        if (String.isNotBlank(idf)) {
            // try Woo order id / OrderNumber first (what a shopper would quote), then SF Id
            found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                            Tracking_Number__c, Carrier__c, Tracking_Url__c,
                            Woo_Order_Id__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                     FROM Order
                     WHERE AccountId = :accountId AND (Woo_Order_Id__c = :idf OR OrderNumber = :idf)
                     ORDER BY CreatedDate DESC LIMIT 1];
            if (found.isEmpty()) {
                try {
                    Id oid = (Id) idf;
                    found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                                    Tracking_Number__c, Carrier__c, Tracking_Url__c,
                                    Woo_Order_Id__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                             FROM Order WHERE Id = :oid AND AccountId = :accountId LIMIT 1];
                } catch (Exception e) { /* not an id */ }
            }
            // A specific identifier was supplied: return it only if it truly matches this account's
            // order. If it doesn't match, return null (NOT the most-recent order) so the agent says
            // "not found" instead of reporting the wrong order.
            return (found != null && !found.isEmpty()) ? found[0] : null;
        }
        // No identifier supplied -> default to the most recent order.
        found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                        Tracking_Number__c, Carrier__c, Tracking_Url__c,
                        Woo_Order_Id__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                 FROM Order WHERE AccountId = :accountId ORDER BY CreatedDate DESC LIMIT 1];
        return found.isEmpty() ? null : found[0];
    }

    public static Boolean canCancel(Order o) {
        return o != null && FulfillmentTruthService.canCancel(o);
    }
    public static Boolean canReturn(Order o) {
        return o != null && FulfillmentTruthService.canReturn(o);
    }

    public static String fulfillment(Order o) {
        return FulfillmentTruthService.effectiveStatus(o);
    }
}
