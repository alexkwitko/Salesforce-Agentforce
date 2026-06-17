// Reports active/deleted row counts for the small Developer Edition org so we
// can free storage without guessing or deleting real demo data.

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
    'Agent_Interaction__c',
    'Customer_Journey__c',
    'Cart__c',
    'Cart_Item__c',
    'Coupon__c',
    'ReturnOrder',
    'ReturnOrderLineItem'
};

Map<String, Object> report = new Map<String, Object>();
for (String objectName : objectNames) {
    Map<String, Integer> counts = new Map<String, Integer>();
    try {
        counts.put(
            'active',
            Database.countQuery('SELECT COUNT() FROM ' + objectName + ' WHERE IsDeleted = false')
        );
    } catch (Exception e) {
        counts.put('active', -1);
    }

    try {
        counts.put(
            'deleted',
            Database.countQuery('SELECT COUNT() FROM ' + objectName + ' WHERE IsDeleted = true ALL ROWS')
        );
    } catch (Exception e) {
        counts.put('deleted', -1);
    }
    report.put(objectName, counts);
}

System.debug('KWITKO_STORAGE_PRESSURE ' + JSON.serialize(report));
