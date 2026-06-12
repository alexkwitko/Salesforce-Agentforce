/**
 * FulfillmentTruthService centralizes commerce fulfillment truth for agent actions.
 *
 * Priority:
 *   1. Shipment delivery event/custom shipment status
 *   2. FulfillmentOrder status
 *   3. Order custom fields as a fallback only
 *
 * Important: WooCommerce "completed" is NOT carrier-delivered. It can mean the store
 * fulfilled/closed the order, so the customer-facing status is Shipped unless a
 * shipment/carrier delivery event proves Delivered.
 */
public without sharing class FulfillmentTruthService {
    public class Snapshot {
        public Id orderId;
        public String orderNumber;
        public String effectiveStatus;
        public String orderFulfillmentStatus;
        public String fulfillmentOrderNumber;
        public String fulfillmentOrderStatus;
        public String shipmentNumber;
        public String shipmentStatus;
        public String trackingNumber;
        public String carrier;
        public String trackingUrl;
        public Datetime shippedAt;
        public Datetime deliveredAt;
        public Boolean hasDeliveryProof;
        public String statusSource;
    }

    private static final Set<String> TERMINAL = new Set<String>{ 'Cancelled', 'Refunded', 'Returned' };

    public static Snapshot forOrder(Order o) {
        Snapshot s = new Snapshot();
        if (o == null) {
            s.effectiveStatus = 'Not Shipped';
            s.statusSource = 'none';
            return s;
        }
        s.orderId = o.Id;
        s.orderNumber = fieldString(o, 'OrderNumber');
        s.orderFulfillmentStatus = fieldString(o, 'Fulfillment_Status__c');
        s.effectiveStatus = orderFallbackStatus(o);
        s.statusSource = 'Order';
        copyOrderTracking(o, s);

        applyFulfillmentOrder(s);
        applyShipment(s);

        if (String.isBlank(s.effectiveStatus)) s.effectiveStatus = 'Not Shipped';
        return s;
    }

    public static String effectiveStatus(Order o) {
        return forOrder(o).effectiveStatus;
    }

    public static Boolean canCancel(Order o) {
        String status = effectiveStatus(o);
        return status == 'Not Shipped' || status == 'Processing';
    }

    public static Boolean canReturn(Order o) {
        return effectiveStatus(o) == 'Delivered';
    }

    public static Boolean hasTracking(Order o) {
        return String.isNotBlank(forOrder(o).trackingNumber);
    }

    public static void syncFromWoo(Order o, String wooStatus, Map<String, String> tracking) {
        if (o == null || o.Id == null) return;
        Order full = [
            SELECT Id, AccountId, OrderNumber, ShippingStreet, ShippingCity, ShippingStateCode,
                   ShippingPostalCode, ShippingCountryCode, Tracking_Number__c, Carrier__c, Tracking_Url__c
            FROM Order WHERE Id = :o.Id LIMIT 1
        ];
        upsertFulfillmentOrder(full, wooStatus);
        upsertShipment(full, wooStatus, tracking);
    }

    private static String orderFallbackStatus(Order o) {
        String rawStatus = fieldString(o, 'Fulfillment_Status__c');
        String wooStatus = fieldString(o, 'Woo_Status__c');
        String trackingNumber = fieldString(o, 'Tracking_Number__c');
        String status = String.isBlank(rawStatus) ? 'Not Shipped' : rawStatus;
        if (TERMINAL.contains(status)) return status;

        // Legacy protection: old sync mapped Woo completed to Delivered. Downshift that
        // to Shipped unless a Shipment/custom delivery event proves delivery.
        if (status == 'Delivered' && wooStatus == 'completed') return 'Shipped';
        if (String.isNotBlank(trackingNumber) && (status == 'Not Shipped' || status == 'Processing')) {
            return 'Shipped';
        }
        return status;
    }

    private static void copyOrderTracking(Order o, Snapshot s) {
        s.trackingNumber = fieldString(o, 'Tracking_Number__c');
        s.carrier = fieldString(o, 'Carrier__c');
        s.trackingUrl = fieldString(o, 'Tracking_Url__c');
    }

    private static void applyFulfillmentOrder(Snapshot s) {
        if (s.orderId == null) return;
        try {
            List<FulfillmentOrder> fos = [
                SELECT Id, FulfillmentOrderNumber, Status
                FROM FulfillmentOrder
                WHERE OrderId = :s.orderId
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
            if (fos.isEmpty()) return;
            FulfillmentOrder fo = fos[0];
            s.fulfillmentOrderNumber = fo.FulfillmentOrderNumber;
            s.fulfillmentOrderStatus = fo.Status;
            String mapped = mapFulfillmentOrderStatus(fo.Status);
            if (shouldPromote(s.effectiveStatus, mapped)) {
                s.effectiveStatus = mapped;
                s.statusSource = 'FulfillmentOrder';
            }
        } catch (Exception e) {
            // FulfillmentOrder may be unavailable in lower-feature orgs. Order fallback remains safe.
        }
    }

    private static void applyShipment(Snapshot s) {
        if (s.orderId == null) return;
        Map<String, Schema.SObjectField> fields = shipmentFields();
        if (!fields.containsKey('Order__c')) return;
        try {
            String soql = 'SELECT Id, ShipmentNumber, ShipToName';
            for (String f : new List<String>{ 'Shipment_Status__c', 'Tracking_Number__c', 'Carrier__c',
                    'Tracking_Url__c', 'Shipped_At__c', 'Delivered_At__c' }) {
                if (fields.containsKey(f)) soql += ', ' + f;
            }
            soql += ' FROM Shipment WHERE Order__c = :orderId ORDER BY LastModifiedDate DESC LIMIT 1';
            Id orderId = s.orderId;
            List<SObject> rows = Database.query(soql);
            if (rows.isEmpty()) return;

            SObject sh = rows[0];
            s.shipmentNumber = (String) sh.get('ShipmentNumber');
            s.shipmentStatus = fieldString(sh, 'Shipment_Status__c');
            s.trackingNumber = prefer(fieldString(sh, 'Tracking_Number__c'), s.trackingNumber);
            s.carrier = prefer(fieldString(sh, 'Carrier__c'), s.carrier);
            s.trackingUrl = prefer(fieldString(sh, 'Tracking_Url__c'), s.trackingUrl);
            s.shippedAt = fieldDatetime(sh, 'Shipped_At__c');
            s.deliveredAt = fieldDatetime(sh, 'Delivered_At__c');
            s.hasDeliveryProof = s.deliveredAt != null || s.shipmentStatus == 'Delivered';

            String mapped = mapShipmentStatus(s.shipmentStatus, s.deliveredAt, s.trackingNumber);
            Boolean sameOrBetterShipmentEvidence = !String.isBlank(mapped)
                && !TERMINAL.contains(s.effectiveStatus)
                && rank(mapped) >= rank(s.effectiveStatus);
            if (shouldPromote(s.effectiveStatus, mapped) || s.hasDeliveryProof || sameOrBetterShipmentEvidence) {
                s.effectiveStatus = mapped;
                s.statusSource = 'Shipment';
            }
        } catch (Exception e) {
            // Shipment is optional until the org has the custom tracking fields deployed.
        }
    }

    private static String mapFulfillmentOrderStatus(String status) {
        if (String.isBlank(status)) return null;
        if (status == 'Cancelled' || status == 'Rejected') return 'Cancelled';
        if (status == 'Fulfilled') return 'Shipped';
        if (status == 'Pick Complete' || status == 'Pack Complete' || status == 'Pickpack'
                || status == 'Allocated' || status == 'Assigned' || status == 'Printed') {
            return 'Processing';
        }
        if (status == 'Draft') return 'Not Shipped';
        return null;
    }

    private static String mapShipmentStatus(String status, Datetime deliveredAt, String trackingNumber) {
        if (deliveredAt != null || status == 'Delivered') return 'Delivered';
        if (status == 'Out for Delivery') return 'Out for Delivery';
        if (status == 'In Transit') return 'In Transit';
        if (status == 'Exception') return 'In Transit';
        if (status == 'Shipped' || String.isNotBlank(trackingNumber)) return 'Shipped';
        return null;
    }

    private static Boolean shouldPromote(String current, String candidate) {
        if (String.isBlank(candidate)) return false;
        if (TERMINAL.contains(current)) return false;
        if (TERMINAL.contains(candidate)) return true;
        return rank(candidate) > rank(current);
    }

    private static Integer rank(String status) {
        if (status == 'Delivered') return 6;
        if (status == 'Out for Delivery') return 5;
        if (status == 'In Transit') return 4;
        if (status == 'Shipped') return 3;
        if (status == 'Processing') return 2;
        if (status == 'Not Shipped') return 1;
        return 0;
    }

    private static void upsertFulfillmentOrder(Order o, String wooStatus) {
        String foStatus = wooToFulfillmentOrderStatus(wooStatus);
        if (String.isBlank(foStatus)) return;
        try {
            List<FulfillmentOrder> existing = [
                SELECT Id, Status FROM FulfillmentOrder WHERE OrderId = :o.Id
                ORDER BY LastModifiedDate DESC LIMIT 1
            ];
            if (!existing.isEmpty()) {
                if (existing[0].Status != foStatus) safeUpdateFulfillmentStatus(existing[0].Id, foStatus);
                return;
            }
            FulfillmentOrder fo = new FulfillmentOrder(
                OrderId = o.Id,
                AccountId = o.AccountId,
                OwnerId = UserInfo.getUserId(),
                Status = 'Draft',
                FulfilledToName = 'Kwitko Customer',
                FulfilledToStreet = o.ShippingStreet,
                FulfilledToCity = o.ShippingCity,
                FulfilledToStateCode = o.ShippingStateCode,
                FulfilledToPostalCode = o.ShippingPostalCode,
                FulfilledToCountryCode = o.ShippingCountryCode,
                IsReship = false,
                IsSuspended = false
            );
            insert fo;
            if (foStatus != 'Draft') safeUpdateFulfillmentStatus(fo.Id, foStatus);
        } catch (Exception e) {
            System.debug('FulfillmentOrder sync skipped: ' + e.getMessage());
        }
    }

    private static String wooToFulfillmentOrderStatus(String wooStatus) {
        String s = String.isBlank(wooStatus) ? '' : wooStatus.toLowerCase();
        if (s == 'processing' || s == 'completed') return 'Assigned';
        if (s == 'pending' || s == 'on-hold' || s == 'failed') return 'Draft';
        return null;
    }

    private static void safeUpdateFulfillmentStatus(Id fulfillmentOrderId, String status) {
        if (fulfillmentOrderId == null || String.isBlank(status)) return;
        Database.SaveResult sr = Database.update(
            new FulfillmentOrder(Id = fulfillmentOrderId, Status = status),
            false
        );
        if (!sr.isSuccess()) {
            for (Database.Error e : sr.getErrors()) {
                System.debug('FulfillmentOrder status update skipped: ' + status + ' - ' + e.getMessage());
            }
        }
    }

    private static void upsertShipment(Order o, String wooStatus, Map<String, String> tracking) {
        String trackingNumber = tracking == null ? null : tracking.get('number');
        if (String.isBlank(trackingNumber)) return;
        Map<String, Schema.SObjectField> fields = shipmentFields();
        if (!fields.containsKey('Order__c') || !fields.containsKey('Tracking_Number__c')) return;
        try {
            Id orderId = o.Id;
            String trackingKey = trackingNumber;
            String existingSoql = 'SELECT Id';
            for (String f : new List<String>{ 'Fulfillment_Order__c', 'Shipment_Status__c', 'Tracking_Number__c',
                    'Carrier__c', 'Tracking_Url__c', 'Shipped_At__c', 'Delivered_At__c',
                    'Last_Event_At__c', 'Last_Event_Description__c' }) {
                if (fields.containsKey(f)) existingSoql += ', ' + f;
            }
            existingSoql += ' FROM Shipment WHERE Order__c = :orderId AND Tracking_Number__c = :trackingKey LIMIT 1';
            List<SObject> existing = Database.query(existingSoql);
            SObject sh = existing.isEmpty()
                ? Schema.getGlobalDescribe().get('Shipment').newSObject()
                : existing[0];
            if (existing.isEmpty()) {
                sh.put('OwnerId', UserInfo.getUserId());
                sh.put('ShipToName', 'Kwitko Customer');
                sh.put('Order__c', o.Id);
            }
            putIfPresent(sh, fields, 'Fulfillment_Order__c', latestFulfillmentOrderId(o.Id));
            putIfPresent(sh, fields, 'Tracking_Number__c', trackingNumber);
            putIfPresent(sh, fields, 'Carrier__c', tracking.get('carrier'));
            putIfPresent(sh, fields, 'Tracking_Url__c', tracking.get('url'));
            putIfPresent(sh, fields, 'Shipment_Status__c', 'Shipped');
            if (fields.containsKey('Shipped_At__c') && sh.get('Shipped_At__c') == null) {
                sh.put('Shipped_At__c', System.now());
            }
            upsert sh;
        } catch (Exception e) {
            System.debug('Shipment sync skipped: ' + e.getMessage());
        }
    }

    private static Id latestFulfillmentOrderId(Id orderId) {
        if (orderId == null) return null;
        List<FulfillmentOrder> fos = [
            SELECT Id FROM FulfillmentOrder
            WHERE OrderId = :orderId
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return fos.isEmpty() ? null : fos[0].Id;
    }

    private static Map<String, Schema.SObjectField> shipmentFields() {
        Schema.SObjectType t = Schema.getGlobalDescribe().get('Shipment');
        if (t == null) return new Map<String, Schema.SObjectField>();
        return t.getDescribe().fields.getMap();
    }

    private static void putIfPresent(SObject row, Map<String, Schema.SObjectField> fields, String fieldName, Object value) {
        if (fields.containsKey(fieldName) && value != null) row.put(fieldName, value);
    }

    private static String fieldString(SObject row, String fieldName) {
        try {
            Object v = row.get(fieldName);
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }

    private static Datetime fieldDatetime(SObject row, String fieldName) {
        try {
            Object v = row.get(fieldName);
            return v == null ? null : (Datetime) v;
        } catch (Exception e) {
            return null;
        }
    }

    private static String prefer(String primary, String fallback) {
        return String.isBlank(primary) ? fallback : primary;
    }
}