/**
 * IdentityStitchService — anonymous->known + cross-device resolver, self-healing against
 * concurrent-identify races. Given (deviceId, email): pick the CANONICAL Person Account for
 * the email (oldest; create if none), then relink every anonymous event for that device AND for
 * any sibling device ever seen with the email AND any events on duplicate accounts -> canonical.
 * So even if two simultaneous logins minted duplicate accounts, the next stitch collapses them.
 */
public without sharing class IdentityStitchService {

    public static Id stitch(String deviceId, String email, String firstName, String lastName) {
        if (String.isBlank(email)) { return null; }
        email = email.toLowerCase().trim();

        // 1) canonical account = oldest for this email; create if none
        Id acctId;
        Set<Id> dupAccts = new Set<Id>();
        List<Account> accs = [SELECT Id FROM Account
                              WHERE IsPersonAccount = true AND PersonEmail = :email
                              ORDER BY CreatedDate ASC, Id ASC];
        if (!accs.isEmpty()) {
            acctId = accs[0].Id;
            for (Integer i = 1; i < accs.size(); i++) { dupAccts.add(accs[i].Id); }
        } else {
            Id rt = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
            Account a = new Account(
                RecordTypeId = rt,
                FirstName = String.isNotBlank(firstName) ? firstName : '',
                LastName  = String.isNotBlank(lastName)  ? lastName  : 'Web Visitor',
                PersonEmail = email);
            insert a;
            acctId = a.Id;
        }

        // 2) every device ever tied to this email or any of these accounts (+ the incoming one)
        Set<Id> allAccts = new Set<Id>{ acctId };
        allAccts.addAll(dupAccts);
        Set<String> devices = new Set<String>();
        if (String.isNotBlank(deviceId)) { devices.add(deviceId); }
        for (Web_Event__c w : [SELECT Device_Id__c FROM Web_Event__c
                               WHERE (Email__c = :email OR Account__c IN :allAccts) AND Device_Id__c != null]) {
            devices.add(w.Device_Id__c);
        }

        // 3) relink all those events (and any on duplicate accounts) to the canonical account
        List<Web_Event__c> ups = new List<Web_Event__c>();
        for (Web_Event__c w : [SELECT Id, Account__c, Email__c FROM Web_Event__c
                               WHERE (Device_Id__c IN :devices OR Account__c IN :dupAccts)]) {
            if (w.Account__c != acctId) { w.Account__c = acctId; }
            if (String.isBlank(w.Email__c)) { w.Email__c = email; }
            ups.add(w);
        }
        if (!ups.isEmpty()) { update ups; }
        return acctId;
    }
}
