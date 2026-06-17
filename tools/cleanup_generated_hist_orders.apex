List<OrderItem> items = [
    SELECT Id
    FROM OrderItem
    WHERE Order.Woo_Order_Id__c = null
      AND Order.Status = 'Draft'
      AND Order.Account.PersonEmail LIKE 'hist%@example.com'
    LIMIT 10000
];

Database.DeleteResult[] itemDeletes = Database.delete(items, false);
List<OrderItem> deletedItems = new List<OrderItem>();
Integer itemDeleteFailures = 0;
for (Integer i = 0; i < itemDeletes.size(); i++) {
    if (itemDeletes[i].isSuccess()) {
        deletedItems.add(items[i]);
    } else {
        itemDeleteFailures++;
    }
}

Integer itemPurgeFailures = 0;
if (!deletedItems.isEmpty()) {
    Database.EmptyRecycleBinResult[] itemPurges = Database.emptyRecycleBin(deletedItems);
    for (Database.EmptyRecycleBinResult r : itemPurges) {
        if (!r.isSuccess()) {
            itemPurgeFailures++;
        }
    }
}

List<Order> orders = [
    SELECT Id
    FROM Order
    WHERE Woo_Order_Id__c = null
      AND Status = 'Draft'
      AND Account.PersonEmail LIKE 'hist%@example.com'
    LIMIT 10000
];

Database.DeleteResult[] orderDeletes = Database.delete(orders, false);
List<Order> deletedOrders = new List<Order>();
Integer orderDeleteFailures = 0;
for (Integer i = 0; i < orderDeletes.size(); i++) {
    if (orderDeletes[i].isSuccess()) {
        deletedOrders.add(orders[i]);
    } else {
        orderDeleteFailures++;
    }
}

Integer orderPurgeFailures = 0;
if (!deletedOrders.isEmpty()) {
    Database.EmptyRecycleBinResult[] orderPurges = Database.emptyRecycleBin(deletedOrders);
    for (Database.EmptyRecycleBinResult r : orderPurges) {
        if (!r.isSuccess()) {
            orderPurgeFailures++;
        }
    }
}

System.debug(
    'KWITKO_GENERATED_HIST_ORDER_CLEANUP ' +
    'itemsDeleted=' + deletedItems.size() + ' ' +
    'itemDeleteFailures=' + itemDeleteFailures + ' ' +
    'itemPurgeFailures=' + itemPurgeFailures + ' ' +
    'ordersDeleted=' + deletedOrders.size() + ' ' +
    'orderDeleteFailures=' + orderDeleteFailures + ' ' +
    'orderPurgeFailures=' + orderPurgeFailures
);
