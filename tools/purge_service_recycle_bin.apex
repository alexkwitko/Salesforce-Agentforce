// Hard-purges records that are already in the Salesforce Recycle Bin for the
// chat/service demo objects. This does not delete any active business data.

List<String> objectNames = new List<String>{
    'Agent_Interaction__c',
    'Cart__c',
    'Cart_Item__c',
    'Case',
    'Chat_Verification__c',
    'Coupon__c',
    'Customer_Journey__c',
    'EmailMessage',
    'FulfillmentOrder',
    'Lead',
    'MessagingSession',
    'Order',
    'OrderItem',
    'ReturnOrder',
    'ReturnOrderLineItem',
    'Shipment',
    'Task',
    'Web_Event__c'
};

Map<String, Integer> purgedByObject = new Map<String, Integer>();
Map<String, String> skippedByObject = new Map<String, String>();

for (String objectName : objectNames) {
    try {
        List<SObject> deletedRows = Database.query(
            'SELECT Id FROM ' + objectName + ' WHERE IsDeleted = true LIMIT 200 ALL ROWS'
        );
        if (!deletedRows.isEmpty()) {
            Database.EmptyRecycleBinResult[] results = Database.emptyRecycleBin(deletedRows);
            Integer failures = 0;
            for (Database.EmptyRecycleBinResult result : results) {
                if (!result.isSuccess()) {
                    failures++;
                }
            }
            purgedByObject.put(objectName, deletedRows.size() - failures);
            if (failures > 0) {
                skippedByObject.put(objectName, String.valueOf(failures) + ' purge failures');
            }
        } else {
            purgedByObject.put(objectName, 0);
        }
    } catch (Exception e) {
        skippedByObject.put(objectName, e.getTypeName() + ': ' + e.getMessage());
    }
}

System.debug('KWITKO_SERVICE_RECYCLE_PURGE purged=' + JSON.serialize(purgedByObject));
System.debug('KWITKO_SERVICE_RECYCLE_PURGE skipped=' + JSON.serialize(skippedByObject));
