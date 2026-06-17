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

    // WooCommerce statuses that are NOT real placed orders (abandoned/incomplete checkouts that
    // sync in but were never purchased). Never surface these as "your order".
    public static final Set<String> NON_ORDER_WOO_STATUSES = new Set<String>{
        'checkout-draft', 'pending', 'failed', 'trash', 'auto-draft' };

    public static String customerOrderNumber(Order o) {
        if (o == null) return null;
        // Customer-facing chat must never expose the internal Salesforce OrderNumber.
        return String.isNotBlank(o.Woo_Order_Id__c) ? o.Woo_Order_Id__c : null;
    }

    public static String displayOrderNumber(Order o) {
        String n = customerOrderNumber(o);
        return String.isBlank(n) ? 'this order' : '#' + n;
    }

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
            Set<String> directIdentifiers = orderIdentifierCandidates(idf, false);
            found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                            Tracking_Number__c, Carrier__c, Tracking_Url__c,
                            Woo_Order_Id__c, Woo_Order_Total__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                     FROM Order
                     WHERE AccountId = :accountId AND (Woo_Order_Id__c IN :directIdentifiers OR OrderNumber IN :directIdentifiers)
                     ORDER BY CreatedDate DESC LIMIT 1];
            if (found.isEmpty()) {
                Set<String> looseIdentifiers = orderIdentifierCandidates(idf, true);
                looseIdentifiers.removeAll(directIdentifiers);
                if (!looseIdentifiers.isEmpty()) {
                        found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                                        Tracking_Number__c, Carrier__c, Tracking_Url__c,
                                        Woo_Order_Id__c, Woo_Order_Total__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                                 FROM Order
                                 WHERE AccountId = :accountId AND (Woo_Order_Id__c IN :looseIdentifiers OR OrderNumber IN :looseIdentifiers)
                                 ORDER BY CreatedDate DESC LIMIT 1];
                }
            }
            if (found.isEmpty()) {
                try {
                    Id oid = (Id) idf;
                    found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                                    Tracking_Number__c, Carrier__c, Tracking_Url__c,
                                    Woo_Order_Id__c, Woo_Order_Total__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                             FROM Order WHERE Id = :oid AND AccountId = :accountId LIMIT 1];
                } catch (Exception e) { /* not an id */ }
            }
            // A specific identifier was supplied: return it only if it truly matches this account's
            // order. If it doesn't match, return null (NOT the most-recent order) so the agent says
            // "not found" instead of reporting the wrong order.
            return (found != null && !found.isEmpty()) ? found[0] : null;
        }
        // No identifier supplied -> default to the most recent REAL order. EXCLUDE WooCommerce
        // non-order statuses (checkout-draft, pending, failed, trash, auto-draft): these are
        // abandoned/incomplete checkouts that sync in but were never actually placed, so they must
        // NEVER be reported as "your last order". Keep null-status legacy orders + real statuses
        // (processing/completed/cancelled/etc.).
        found = [SELECT Id, OrderNumber, Status, Fulfillment_Status__c, Woo_Status__c,
                        Tracking_Number__c, Carrier__c, Tracking_Url__c,
                        Woo_Order_Id__c, Woo_Order_Total__c, TotalAmount, AccountId, EffectiveDate, ShippingStreet, ShippingCity
                 FROM Order
                 WHERE AccountId = :accountId
                   AND (Woo_Status__c = null OR Woo_Status__c NOT IN :NON_ORDER_WOO_STATUSES)
                 ORDER BY CreatedDate DESC LIMIT 1];
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

    private static Set<String> orderIdentifierCandidates(String identifier, Boolean includeTrimmedLeadingZeros) {
        Set<String> out = new Set<String>();
        addOrderIdentifier(out, identifier, includeTrimmedLeadingZeros);
        if (String.isBlank(identifier)) return out;
        String cleaned = identifier.trim()
            .replaceAll('(?i)\\b(order|number|woo|id|no)\\b', ' ')
            .replaceAll('[^A-Za-z0-9]', ' ')
            .trim();
        addOrderIdentifier(out, cleaned, includeTrimmedLeadingZeros);
        for (String token : cleaned.split('\\s+')) addOrderIdentifier(out, token, includeTrimmedLeadingZeros);
        addOrderIdentifier(out, identifier.replaceAll('[^0-9]', ''), includeTrimmedLeadingZeros);
        if (out.isEmpty()) out.add(identifier.trim());
        return out;
    }

    private static void addOrderIdentifier(Set<String> out, String value, Boolean includeTrimmedLeadingZeros) {
        if (String.isBlank(value)) return;
        String v = value.trim();
        if (String.isBlank(v)) return;
        out.add(v);
        String withoutHashes = v.replaceAll('^#+', '');
        if (String.isNotBlank(withoutHashes)) out.add(withoutHashes);
        if (includeTrimmedLeadingZeros) {
            String digits = v.replaceAll('[^0-9]', '');
            if (String.isNotBlank(digits)) {
                String noLeadingZeros = digits.replaceFirst('^0+', '');
                if (String.isNotBlank(noLeadingZeros)) out.add(noLeadingZeros);
            }
        }
    }
}
