// Safe live repair for the existing Kwitko return on Woo order 506.
// No refund is issued. This only re-pulls Woo order metadata, restores the
// Salesforce order lifecycle to Return Pending for the open return, and fills
// missing Woo line ids on Salesforce OrderItems/ReturnOrderLineItems.

String wooOrderId = '506';

HttpRequest req = new HttpRequest();
req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders/' + wooOrderId);
req.setMethod('GET');
req.setTimeout(60000);
HttpResponse resp = new Http().send(req);
if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
    System.debug('KWITKO_RETURN_506_REPAIR failed_get status=' + resp.getStatusCode() + ' body=' + resp.getBody());
    return;
}

Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
Id orderId = WooOrderService.ingestOrder(payload);

Order orderRecord = [
    SELECT Id, Fulfillment_Status__c, Payment_Status__c, Woo_Order_Id__c
    FROM Order
    WHERE Id = :orderId
    LIMIT 1
];

Integer openReturnCount = [
    SELECT count()
    FROM ReturnOrder
    WHERE Order__c = :orderRecord.Id
      AND Status != 'Closed'
];

List<Case> openReturnCases = [
    SELECT Id, CaseNumber
    FROM Case
    WHERE Order__c = :orderRecord.Id
      AND Category__c = 'Returns'
      AND Status != 'Closed'
    ORDER BY CreatedDate ASC
    LIMIT 1
];

List<ReturnOrder> returnCaseUpdates = new List<ReturnOrder>();
if (!openReturnCases.isEmpty()) {
    for (ReturnOrder ro : [
        SELECT Id, CaseId
        FROM ReturnOrder
        WHERE Order__c = :orderRecord.Id
          AND Status != 'Closed'
          AND CaseId = null
    ]) {
        returnCaseUpdates.add(new ReturnOrder(Id = ro.Id, CaseId = openReturnCases[0].Id));
    }
    if (!returnCaseUpdates.isEmpty()) update returnCaseUpdates;
}

Boolean orderUpdated = false;
if (openReturnCount > 0 && orderRecord.Fulfillment_Status__c != 'Return Pending') {
    update new Order(
        Id = orderRecord.Id,
        Fulfillment_Status__c = 'Return Pending',
        Last_Status_Change__c = System.now(),
        Status_Note__c = 'Open return metadata repaired from Woo order ' + wooOrderId
            + '; refund remains pending merchandise receipt.'
    );
    orderUpdated = true;
}

Map<Id, List<OrderItem>> orderItemsByProduct = new Map<Id, List<OrderItem>>();
for (OrderItem item : [
    SELECT Id, Product2Id, Quantity, UnitPrice, Woo_Line_Item_Id__c
    FROM OrderItem
    WHERE OrderId = :orderRecord.Id
      AND Woo_Line_Item_Id__c != null
]) {
    if (!orderItemsByProduct.containsKey(item.Product2Id)) {
        orderItemsByProduct.put(item.Product2Id, new List<OrderItem>());
    }
    orderItemsByProduct.get(item.Product2Id).add(item);
}

List<ReturnOrderLineItem> returnLineUpdates = new List<ReturnOrderLineItem>();
for (ReturnOrderLineItem line : [
    SELECT Id, OrderItemId, Product2Id, QuantityReturned, UnitPrice, Woo_Line_Item_Id__c
    FROM ReturnOrderLineItem
    WHERE ReturnOrder.Order__c = :orderRecord.Id
      AND ReturnOrder.Status != 'Closed'
]) {
    if (line.OrderItemId != null && String.isNotBlank(line.Woo_Line_Item_Id__c)) continue;

    List<OrderItem> candidates = orderItemsByProduct.get(line.Product2Id);
    if (candidates == null || candidates.isEmpty()) continue;

    List<OrderItem> exact = new List<OrderItem>();
    for (OrderItem candidate : candidates) {
        Boolean qtyMatches = line.QuantityReturned == null || candidate.Quantity == line.QuantityReturned;
        Boolean unitMatches = line.UnitPrice == null || candidate.UnitPrice == line.UnitPrice;
        if (qtyMatches && unitMatches) exact.add(candidate);
    }

    OrderItem match = exact.size() == 1 ? exact[0] : (candidates.size() == 1 ? candidates[0] : null);
    if (match == null || String.isBlank(match.Woo_Line_Item_Id__c)) continue;

    returnLineUpdates.add(new ReturnOrderLineItem(
        Id = line.Id,
        OrderItemId = match.Id,
        Woo_Line_Item_Id__c = match.Woo_Line_Item_Id__c
    ));
}
if (!returnLineUpdates.isEmpty()) update returnLineUpdates;

Integer orderItemsWithWooLineIds = [
    SELECT count()
    FROM OrderItem
    WHERE OrderId = :orderRecord.Id
      AND Woo_Line_Item_Id__c != null
];
Integer returnLinesWithWooLineIds = [
    SELECT count()
    FROM ReturnOrderLineItem
    WHERE ReturnOrder.Order__c = :orderRecord.Id
      AND ReturnOrder.Status != 'Closed'
      AND Woo_Line_Item_Id__c != null
];

System.debug(
    'KWITKO_RETURN_506_REPAIR orderId=' + orderRecord.Id
    + ' openReturns=' + openReturnCount
    + ' orderUpdated=' + orderUpdated
    + ' returnCaseLinked=' + returnCaseUpdates.size()
    + ' orderItemsWithWooLineIds=' + orderItemsWithWooLineIds
    + ' returnLineUpdates=' + returnLineUpdates.size()
    + ' returnLinesWithWooLineIds=' + returnLinesWithWooLineIds
);
