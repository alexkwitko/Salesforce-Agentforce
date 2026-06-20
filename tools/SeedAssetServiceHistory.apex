// Seed realistic field-service history so call-rate + fix-right-first-time are meaningful.
Date t = Date.today();

WorkOrder doneWO(Id assetId, Id acctId, Integer reportedAgo, Integer servicedAgo, String subj) {
    return new WorkOrder(
        AssetId = assetId, AccountId = acctId, Status = 'Completed', Subject = subj,
        Reported_Date__c = Date.today().addDays(-reportedAgo),
        Service_Date__c  = Date.today().addDays(-servicedAgo));
}

// ---- Asset A: existing Blue Bottle Pro Espresso Machine (problem machine) ----
Asset bb = [SELECT Id, AccountId FROM Asset WHERE Id = '02ifj000002Ook5AAC' LIMIT 1];
// repurpose its 3 existing 'New' WOs as completed history
List<WorkOrder> bbExisting = [SELECT Id FROM WorkOrder WHERE AssetId = :bb.Id ORDER BY CreatedDate ASC];
Integer[] rep = new Integer[]{302, 202, 192};      // reported-ago
Integer[] svc = new Integer[]{300, 200, 190};      // serviced-ago (190 is a repeat of 200)
for (Integer i = 0; i < bbExisting.size() && i < 3; i++) {
    bbExisting[i].Status = 'Completed';
    bbExisting[i].Reported_Date__c = t.addDays(-rep[i]);
    bbExisting[i].Service_Date__c  = t.addDays(-svc[i]);
}
update bbExisting;
insert new List<WorkOrder>{
    doneWO(bb.Id, bb.AccountId, 122, 120, 'Steam wand leak'),
    doneWO(bb.Id, bb.AccountId, 62,  60,  'Boiler pressure fault'),
    doneWO(bb.Id, bb.AccountId, 52,  50,  'Boiler pressure recurring')  // repeat of -60
};

// ---- helper to make a new equipment asset + its history ----
Map<String, Id> acctByName = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE Name IN ('Acme Roasters','Bluebird Cafe','Downtown Diner')]) {
    acctByName.put(a.Name, a.Id);
}

List<Asset> newAssets = new List<Asset>();
Asset acme = new Asset(Name = 'Acme — Commercial Burr Grinder', AccountId = acctByName.get('Acme Roasters'),
                       SerialNumber = 'GRD-AC-2207', Status = 'Installed', InstallDate = t.addDays(-400));
Asset blue = new Asset(Name = 'Bluebird — Pro Espresso Machine', AccountId = acctByName.get('Bluebird Cafe'),
                       SerialNumber = 'ESP-BL-3310', Status = 'Installed', InstallDate = t.addDays(-260));
Asset dt   = new Asset(Name = 'Downtown — Drip Brewer Station', AccountId = acctByName.get('Downtown Diner'),
                       SerialNumber = 'DRP-DT-0099', Status = 'Installed', InstallDate = t.addDays(-90));
newAssets.add(acme); newAssets.add(blue); newAssets.add(dt);
insert newAssets;

List<WorkOrder> hist = new List<WorkOrder>();
// Acme grinder: healthy — 2 calls, no repeats
hist.add(doneWO(acme.Id, acme.AccountId, 182, 180, 'Burr calibration'));
hist.add(doneWO(acme.Id, acme.AccountId, 42,  40,  'Annual maintenance'));
// Bluebird espresso: medium — 4 calls, 1 repeat
hist.add(doneWO(blue.Id, blue.AccountId, 222, 220, 'Group head seal'));
hist.add(doneWO(blue.Id, blue.AccountId, 132, 130, 'Descale + service'));
hist.add(doneWO(blue.Id, blue.AccountId, 47,  45,  'Temp sensor fault'));
hist.add(doneWO(blue.Id, blue.AccountId, 32,  30,  'Temp sensor recurring')); // repeat of -45
// Downtown drip: new — 1 completed + 1 currently open
hist.add(doneWO(dt.Id, dt.AccountId, 22, 20, 'Install follow-up'));
hist.add(new WorkOrder(AssetId = dt.Id, AccountId = dt.AccountId, Status = 'New', Subject = 'Flow rate low'));
insert hist;

// ---- recalc all ----
AssetServiceMetricsService.recalculateAll();
System.debug('Seed + recalc complete. Assets: ' + new List<Id>{ bb.Id, acme.Id, blue.Id, dt.Id });
