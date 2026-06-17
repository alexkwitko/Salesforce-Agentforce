// Frees active data storage by removing older service/chat certification
// artifacts. Keeps current June 14/15 proof records and never touches Accounts,
// Contacts, Orders, OrderItems, Products, or current ReturnOrders.

DateTime cutoff = DateTime.newInstanceGmt(2026, 6, 14, 0, 0, 0);

Map<String, Integer> deletedByObject = new Map<String, Integer>();
Map<String, Integer> deleteFailuresByObject = new Map<String, Integer>();
Map<String, Integer> purgeFailuresByObject = new Map<String, Integer>();
List<String> objectNames = new List<String>{
    'Task',
    'Agent_Interaction__c',
    'Customer_Journey__c',
    'MessagingSession',
    'Case',
    'Cart_Item__c',
    'Cart__c'
};

String old = 'CreatedDate < ' + cutoff.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

for (String objectName : objectNames) {
    List<SObject> rows = Database.query(
        'SELECT Id FROM ' + objectName + ' WHERE ' + old + ' LIMIT 500'
    );

    if (rows.isEmpty()) {
        deletedByObject.put(objectName, 0);
        deleteFailuresByObject.put(objectName, 0);
        purgeFailuresByObject.put(objectName, 0);
        continue;
    }

    Database.DeleteResult[] deletes = Database.delete(rows, false);
    List<SObject> deletedRows = new List<SObject>();
    Integer deleteFailures = 0;
    for (Integer i = 0; i < deletes.size(); i++) {
        if (deletes[i].isSuccess()) {
            deletedRows.add(rows[i]);
        } else {
            deleteFailures++;
        }
    }

    Integer purgeFailures = 0;
    if (!deletedRows.isEmpty()) {
        Database.EmptyRecycleBinResult[] purges = Database.emptyRecycleBin(deletedRows);
        for (Database.EmptyRecycleBinResult purge : purges) {
            if (!purge.isSuccess()) {
                purgeFailures++;
            }
        }
    }

    deletedByObject.put(objectName, deletedRows.size());
    deleteFailuresByObject.put(objectName, deleteFailures);
    purgeFailuresByObject.put(objectName, purgeFailures);
}

System.debug('KWITKO_OLD_SERVICE_ARTIFACT_CLEANUP deleted=' + JSON.serialize(deletedByObject));
System.debug('KWITKO_OLD_SERVICE_ARTIFACT_CLEANUP deleteFailures=' + JSON.serialize(deleteFailuresByObject));
System.debug('KWITKO_OLD_SERVICE_ARTIFACT_CLEANUP purgeFailures=' + JSON.serialize(purgeFailuresByObject));
