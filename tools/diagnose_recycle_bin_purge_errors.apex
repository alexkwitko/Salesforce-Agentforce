// Samples recycle-bin purge errors so storage cleanup can be targeted safely.

List<String> objectNames = new List<String>{
    'Account',
    'Contact',
    'Order',
    'OrderItem',
    'Web_Event__c',
    'MessagingSession',
    'Case',
    'Task',
    'Chat_Verification__c',
    'Cart__c',
    'Cart_Item__c',
    'Coupon__c',
    'ReturnOrder',
    'ReturnOrderLineItem'
};

Map<String, List<String>> failuresByObject = new Map<String, List<String>>();
Map<String, Integer> successesByObject = new Map<String, Integer>();

for (String objectName : objectNames) {
    try {
        List<SObject> deletedRows = Database.query(
            'SELECT Id FROM ' + objectName + ' WHERE IsDeleted = true LIMIT 5 ALL ROWS'
        );
        if (deletedRows.isEmpty()) {
            successesByObject.put(objectName, 0);
            continue;
        }

        Database.EmptyRecycleBinResult[] results = Database.emptyRecycleBin(deletedRows);
        Integer successes = 0;
        List<String> errors = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successes++;
            } else {
                for (Database.Error error : results[i].getErrors()) {
                    errors.add(
                        String.valueOf(deletedRows[i].get('Id'))
                        + ': ' + error.getStatusCode()
                        + ' ' + error.getMessage()
                    );
                }
            }
        }
        successesByObject.put(objectName, successes);
        if (!errors.isEmpty()) {
            failuresByObject.put(objectName, errors);
        }
    } catch (Exception e) {
        failuresByObject.put(
            objectName,
            new List<String>{e.getTypeName() + ': ' + e.getMessage()}
        );
    }
}

System.debug('KWITKO_RECYCLE_PURGE_SAMPLE successes=' + JSON.serialize(successesByObject));
System.debug('KWITKO_RECYCLE_PURGE_SAMPLE failures=' + JSON.serialize(failuresByObject));
