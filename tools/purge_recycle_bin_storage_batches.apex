// Hard-purges already-deleted rows in safe 200-record batches.
// This frees Developer Edition data storage without deleting active demo data.

List<String> objectNames = new List<String>{
    'Account',
    'Contact',
    'Lead',
    'Order',
    'OrderItem',
    'Web_Event__c',
    'MessagingSession',
    'Case',
    'Task',
    'Chat_Verification__c',
    'Agent_Interaction__c',
    'Customer_Journey__c',
    'Cart__c',
    'Cart_Item__c',
    'Coupon__c',
    'ReturnOrder',
    'ReturnOrderLineItem',
    'EmailMessage',
    'FulfillmentOrder',
    'Shipment'
};

Map<String, Integer> purgedByObject = new Map<String, Integer>();
Map<String, Integer> failedByObject = new Map<String, Integer>();
Map<String, String> skippedByObject = new Map<String, String>();

for (String objectName : objectNames) {
    try {
        List<SObject> deletedRows = Database.query(
            'SELECT Id FROM ' + objectName + ' WHERE IsDeleted = true LIMIT 200 ALL ROWS'
        );

        if (deletedRows.isEmpty()) {
            purgedByObject.put(objectName, 0);
            failedByObject.put(objectName, 0);
            continue;
        }

        Database.EmptyRecycleBinResult[] results = Database.emptyRecycleBin(deletedRows);
        Integer purged = 0;
        Integer failed = 0;
        for (Database.EmptyRecycleBinResult result : results) {
            if (result.isSuccess()) {
                purged++;
            } else {
                failed++;
            }
        }

        purgedByObject.put(objectName, purged);
        failedByObject.put(objectName, failed);
    } catch (Exception e) {
        skippedByObject.put(objectName, e.getTypeName() + ': ' + e.getMessage());
    }
}

System.debug('KWITKO_RECYCLE_BIN_BATCH_PURGE purged=' + JSON.serialize(purgedByObject));
System.debug('KWITKO_RECYCLE_BIN_BATCH_PURGE failed=' + JSON.serialize(failedByObject));
System.debug('KWITKO_RECYCLE_BIN_BATCH_PURGE skipped=' + JSON.serialize(skippedByObject));
