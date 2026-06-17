List<Order> deletedOrders = [
    SELECT Id
    FROM Order
    WHERE IsDeleted = true
      AND Woo_Order_Id__c = null
      AND Status = 'Draft'
      AND Account.PersonEmail LIKE 'hist%@example.com'
    ALL ROWS
];

Set<Id> orderIds = new Set<Id>();
for (Order o : deletedOrders) {
    orderIds.add(o.Id);
}

List<OrderItem> deletedItems = orderIds.isEmpty()
    ? new List<OrderItem>()
    : [
        SELECT Id
        FROM OrderItem
        WHERE IsDeleted = true
          AND OrderId IN :orderIds
        ALL ROWS
    ];

Integer itemPurgeFailures = 0;
String firstItemPurgeError = null;
if (!deletedItems.isEmpty()) {
    Database.EmptyRecycleBinResult[] itemPurges = Database.emptyRecycleBin(deletedItems);
    for (Database.EmptyRecycleBinResult r : itemPurges) {
        if (!r.isSuccess()) {
            itemPurgeFailures++;
            if (firstItemPurgeError == null && !r.getErrors().isEmpty()) {
                firstItemPurgeError = r.getErrors()[0].getStatusCode() + ':' + r.getErrors()[0].getMessage();
            }
        }
    }
}

Integer orderPurgeFailures = 0;
String firstOrderPurgeError = null;
if (!deletedOrders.isEmpty()) {
    Database.EmptyRecycleBinResult[] orderPurges = Database.emptyRecycleBin(deletedOrders);
    for (Database.EmptyRecycleBinResult r : orderPurges) {
        if (!r.isSuccess()) {
            orderPurgeFailures++;
            if (firstOrderPurgeError == null && !r.getErrors().isEmpty()) {
                firstOrderPurgeError = r.getErrors()[0].getStatusCode() + ':' + r.getErrors()[0].getMessage();
            }
        }
    }
}

System.debug(
    'KWITKO_GENERATED_HIST_RECYCLE_PURGE ' +
    'deletedItemsFound=' + deletedItems.size() + ' ' +
    'itemPurgeFailures=' + itemPurgeFailures + ' ' +
    'firstItemPurgeError=' + firstItemPurgeError + ' ' +
    'deletedOrdersFound=' + deletedOrders.size() + ' ' +
    'orderPurgeFailures=' + orderPurgeFailures + ' ' +
    'firstOrderPurgeError=' + firstOrderPurgeError
);
