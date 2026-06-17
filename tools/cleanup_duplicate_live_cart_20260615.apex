// Removes the duplicate anonymous live-cart row created by the pre-fix race.
// Keeps CART-0017 and deletes/purges CART-0016 plus its copied line items.

Id duplicateCartId = 'a01fj00001JgdeDAAR';

List<Cart_Item__c> duplicateItems = [
    SELECT Id
    FROM Cart_Item__c
    WHERE Cart__c = :duplicateCartId
];
Database.DeleteResult[] itemDeletes = Database.delete(duplicateItems, false);
Integer itemDeleteFailures = 0;
List<Cart_Item__c> deletedItems = new List<Cart_Item__c>();
for (Integer i = 0; i < itemDeletes.size(); i++) {
    if (itemDeletes[i].isSuccess()) {
        deletedItems.add(duplicateItems[i]);
    } else {
        itemDeleteFailures++;
    }
}

Integer itemPurgeFailures = 0;
if (!deletedItems.isEmpty()) {
    for (Database.EmptyRecycleBinResult result : Database.emptyRecycleBin(deletedItems)) {
        if (!result.isSuccess()) {
            itemPurgeFailures++;
        }
    }
}

List<Cart__c> duplicateCarts = [
    SELECT Id, Name, Woo_Cart_Id__c
    FROM Cart__c
    WHERE Id = :duplicateCartId
      AND Woo_Cart_Id__c = 't_cabc2af36b20f52dd92f5fb606eea4'
      AND Shopper_Email__c = null
      AND Customer__c = null
      AND Lead__c = null
    LIMIT 1
];
Database.DeleteResult[] cartDeletes = Database.delete(duplicateCarts, false);
Integer cartDeleteFailures = 0;
List<Cart__c> deletedCarts = new List<Cart__c>();
for (Integer i = 0; i < cartDeletes.size(); i++) {
    if (cartDeletes[i].isSuccess()) {
        deletedCarts.add(duplicateCarts[i]);
    } else {
        cartDeleteFailures++;
    }
}

Integer cartPurgeFailures = 0;
if (!deletedCarts.isEmpty()) {
    for (Database.EmptyRecycleBinResult result : Database.emptyRecycleBin(deletedCarts)) {
        if (!result.isSuccess()) {
            cartPurgeFailures++;
        }
    }
}

System.debug(
    'KWITKO_DUPLICATE_CART_CLEANUP '
    + 'itemsFound=' + duplicateItems.size()
    + ' itemsDeleted=' + deletedItems.size()
    + ' itemDeleteFailures=' + itemDeleteFailures
    + ' itemPurgeFailures=' + itemPurgeFailures
    + ' cartsFound=' + duplicateCarts.size()
    + ' cartsDeleted=' + deletedCarts.size()
    + ' cartDeleteFailures=' + cartDeleteFailures
    + ' cartPurgeFailures=' + cartPurgeFailures
);
