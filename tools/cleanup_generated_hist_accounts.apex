// Frees Developer Edition data storage by removing generated historical
// prediction-demo Person Accounts after their orders/training rows have been
// purged. These rows use histNNN@example.com and have no Woo customer id.

List<Account> generatedAccounts = [
    SELECT Id
    FROM Account
    WHERE PersonEmail LIKE 'hist%@example.com'
      AND Woo_Customer_Id__c = null
    LIMIT 200
];

Set<Id> generatedAccountIds = new Set<Id>();
for (Account accountRecord : generatedAccounts) {
    generatedAccountIds.add(accountRecord.Id);
}

List<Coupon__c> generatedCoupons = generatedAccountIds.isEmpty()
    ? new List<Coupon__c>()
    : [
        SELECT Id
        FROM Coupon__c
        WHERE Account__c IN :generatedAccountIds
        LIMIT 200
    ];

Integer couponDeleteFailures = 0;
List<Coupon__c> deletedCoupons = new List<Coupon__c>();
if (!generatedCoupons.isEmpty()) {
    Database.DeleteResult[] couponDeletes = Database.delete(generatedCoupons, false);
    for (Integer i = 0; i < couponDeletes.size(); i++) {
        if (couponDeletes[i].isSuccess()) {
            deletedCoupons.add(generatedCoupons[i]);
        } else {
            couponDeleteFailures++;
        }
    }
    if (!deletedCoupons.isEmpty()) {
        Database.emptyRecycleBin(deletedCoupons);
    }
}

Integer accountDeleteFailures = 0;
List<Account> deletedAccounts = new List<Account>();
if (!generatedAccounts.isEmpty()) {
    Database.DeleteResult[] accountDeletes = Database.delete(generatedAccounts, false);
    for (Integer i = 0; i < accountDeletes.size(); i++) {
        if (accountDeletes[i].isSuccess()) {
            deletedAccounts.add(generatedAccounts[i]);
        } else {
            accountDeleteFailures++;
        }
    }
    if (!deletedAccounts.isEmpty()) {
        Database.emptyRecycleBin(deletedAccounts);
    }
}

List<Contact> deletedContacts = [
    SELECT Id
    FROM Contact
    WHERE IsDeleted = true
      AND Email LIKE 'hist%@example.com'
    ALL ROWS
];
if (!deletedContacts.isEmpty()) {
    Database.emptyRecycleBin(deletedContacts);
}

System.debug(
    'KWITKO_GENERATED_HIST_ACCOUNT_CLEANUP '
    + 'couponsDeleted=' + deletedCoupons.size() + ' '
    + 'couponDeleteFailures=' + couponDeleteFailures + ' '
    + 'accountsDeleted=' + deletedAccounts.size() + ' '
    + 'accountDeleteFailures=' + accountDeleteFailures + ' '
    + 'contactsPurged=' + deletedContacts.size()
);
