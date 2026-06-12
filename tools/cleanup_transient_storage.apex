// Frees Developer Edition data storage by removing rows that are explicitly
// generated/test-only for this build.
//
// Safe buckets:
// - Web_Event__c rows with Device_Id__c = STORAGE-PROBE are synthetic endpoint probes.
// - Churn_Training__c rows are generated model-input snapshots. The prediction runbook
//   says to clean them up after the Data Cloud stream syncs.
// - Records already in the Recycle Bin are hard-purged so they stop consuming
//   the tiny 5 MB Developer Edition data quota.
List<Web_Event__c> probes = [
    SELECT Id
    FROM Web_Event__c
    WHERE Device_Id__c = 'STORAGE-PROBE'
];
List<Churn_Training__c> trainingRows = [
    SELECT Id
    FROM Churn_Training__c
];

Integer probeCount = probes.size();
Integer trainingCount = trainingRows.size();

if (!probes.isEmpty()) {
    delete probes;
    Database.emptyRecycleBin(probes);
}
if (!trainingRows.isEmpty()) {
    delete trainingRows;
    Database.emptyRecycleBin(trainingRows);
}

List<Account> deletedAccounts = [
    SELECT Id
    FROM Account
    WHERE IsDeleted = true
    ALL ROWS
];
List<Contact> deletedContacts = [
    SELECT Id
    FROM Contact
    WHERE IsDeleted = true
    ALL ROWS
];
List<Order> deletedOrders = [
    SELECT Id
    FROM Order
    WHERE IsDeleted = true
    ALL ROWS
];
List<Web_Event__c> deletedWebEvents = [
    SELECT Id
    FROM Web_Event__c
    WHERE IsDeleted = true
    ALL ROWS
];

Integer deletedAccountCount = deletedAccounts.size();
Integer deletedContactCount = deletedContacts.size();
Integer deletedOrderCount = deletedOrders.size();
Integer deletedWebEventCount = deletedWebEvents.size();

if (!deletedAccounts.isEmpty()) {
    Database.emptyRecycleBin(deletedAccounts);
}
if (!deletedContacts.isEmpty()) {
    Database.emptyRecycleBin(deletedContacts);
}
if (!deletedOrders.isEmpty()) {
    Database.emptyRecycleBin(deletedOrders);
}
if (!deletedWebEvents.isEmpty()) {
    Database.emptyRecycleBin(deletedWebEvents);
}

System.debug(
    'KWITKO_STORAGE_CLEANUP probes=' + probeCount
    + ' training=' + trainingCount
    + ' purgedAccounts=' + deletedAccountCount
    + ' purgedContacts=' + deletedContactCount
    + ' purgedOrders=' + deletedOrderCount
    + ' purgedWebEvents=' + deletedWebEventCount
);
