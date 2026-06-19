/**
 * OrderBrandStamp — stamps Order.Brand__c (the multi-brand Data Cloud dimension) from the order's products.
 * Bean & Brew products carry Family='Bean & Brew'; anything else defaults to 'Kwitko Coffee'.
 * The customer still unifies across brands via Identity Resolution; this only tags the order.
 */
public without sharing class OrderBrandStamp {
    public static void stamp(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;
        Map<Id,String> brandByOrder = new Map<Id,String>();
        for (OrderItem oi : [SELECT OrderId, Product2.Family FROM OrderItem WHERE OrderId IN :orderIds]) {
            Boolean isBB = (oi.Product2 != null && oi.Product2.Family == 'Bean & Brew');
            String current = brandByOrder.get(oi.OrderId);
            // Bean & Brew wins if any BB product is on the order; else Kwitko Coffee
            if (isBB) brandByOrder.put(oi.OrderId, 'Bean & Brew');
            else if (current == null) brandByOrder.put(oi.OrderId, 'Kwitko Coffee');
        }
        List<Order> ups = new List<Order>();
        for (Order o : [SELECT Id, Brand__c, Woo_Order_Id__c, Fulfillment_Status__c FROM Order WHERE Id IN :orderIds]) {
            Boolean changed = false;
            String b = brandByOrder.get(o.Id);
            if (b != null && o.Brand__c != b) { o.Brand__c = b; changed = true; }
            // Enroll native D2C storefront orders (no Woo origin) into the SAME unified fulfillment
            // pipeline as Woo orders: give them the standard starting status so ShippingService /
            // TrackingService / FulfillmentTruthService / OrderStatusService treat them identically.
            if (String.isBlank(o.Woo_Order_Id__c) && String.isBlank(o.Fulfillment_Status__c)) {
                o.Fulfillment_Status__c = 'Not Shipped';
                changed = true;
            }
            if (changed) ups.add(o);
        }
        if (!ups.isEmpty()) update ups;
    }
}
