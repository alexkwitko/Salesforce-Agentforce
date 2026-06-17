// Removes expired one-time chat verification records. These are transient OTP
// artifacts and should not be retained after their expiration window.

List<Chat_Verification__c> expiredRows = [
    SELECT Id
    FROM Chat_Verification__c
    WHERE Expires_At__c < :System.now()
    LIMIT 200
];

Database.DeleteResult[] deletes = Database.delete(expiredRows, false);
List<Chat_Verification__c> deletedRows = new List<Chat_Verification__c>();
Integer deleteFailures = 0;
for (Integer i = 0; i < deletes.size(); i++) {
    if (deletes[i].isSuccess()) {
        deletedRows.add(expiredRows[i]);
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

System.debug(
    'KWITKO_EXPIRED_VERIFICATION_CLEANUP '
    + 'expiredFound=' + expiredRows.size() + ' '
    + 'deleted=' + deletedRows.size() + ' '
    + 'deleteFailures=' + deleteFailures + ' '
    + 'purgeFailures=' + purgeFailures
);
