/**
 * ShippingService — generates a (test/simulated) return shipping label + tracking number for a return.
     * "Playing, not real" per the build: we mint a tracking number and a label URL. No real carrier.
     * Also best-effort creates a Shipment record using Kwitko custom shipment fields.
 */
public without sharing class ShippingService {

    private static final String STORE = 'https://deepskyblue-deer-920559.hostingersite.com';

    public class LabelResult {
        public String trackingNumber;
        public String labelUrl;
        public Id shipmentId;
    }

    /** Build the (test) return label data — NO DML and NO callout, safe to call before/after callouts. */
    public static LabelResult buildReturnLabel(String orderNumber) {
        LabelResult lr = new LabelResult();
        String rnd = String.valueOf(Math.abs(Crypto.getRandomInteger()));
        rnd = rnd.length() >= 8 ? rnd.right(8) : rnd.leftPad(8, '0');
        lr.trackingNumber = 'KWRET' + rnd;
        // Test return label: a static return-label page on the storefront keyed by tracking (AST can host this).
        lr.labelUrl = STORE + '/return-label/?tracking=' + lr.trackingNumber
                    + (String.isBlank(orderNumber) ? '' : '&order=' + EncodingUtil.urlEncode(orderNumber, 'UTF-8'));
        return lr;
    }

    /** Best-effort Shipment record for the return leg (DML; call in the DML phase). Returns its Id or null. */
    public static Id createReturnShipment(LabelResult lr, String orderNumber) {
        return createReturnShipment(lr, orderNumber, null);
    }

    /** Best-effort Shipment record for the return leg, linked to the source order when available. */
    public static Id createReturnShipment(LabelResult lr, String orderNumber, Id orderId) {
        try {
            SObject s = Schema.getGlobalDescribe().get('Shipment').newSObject();
            Map<String, Schema.SObjectField> fields = Schema.getGlobalDescribe().get('Shipment').getDescribe().fields.getMap();
            s.put('OwnerId', UserInfo.getUserId());
            s.put('ShipToName', 'Kwitko Returns');
            if (orderId != null && fields.containsKey('Order__c')) s.put('Order__c', orderId);
            if (orderId != null && fields.containsKey('Fulfillment_Order__c')) {
                List<FulfillmentOrder> fos = [
                    SELECT Id FROM FulfillmentOrder
                    WHERE OrderId = :orderId
                    ORDER BY LastModifiedDate DESC
                    LIMIT 1
                ];
                if (!fos.isEmpty()) s.put('Fulfillment_Order__c', fos[0].Id);
            }
            if (fields.containsKey('Shipment_Status__c')) s.put('Shipment_Status__c', 'Shipped');
            if (fields.containsKey('Tracking_Number__c')) s.put('Tracking_Number__c', lr.trackingNumber);
            if (fields.containsKey('Tracking_Url__c')) s.put('Tracking_Url__c', lr.labelUrl);
            if (fields.containsKey('Shipped_At__c')) s.put('Shipped_At__c', System.now());
            if (fields.containsKey('Last_Event_Description__c')) s.put('Last_Event_Description__c', 'Return label (test) for order ' + orderNumber);
            insert s;
            return (Id) s.get('Id');
        } catch (Exception e) { return null; } // Shipment optional for the demo
    }
}
