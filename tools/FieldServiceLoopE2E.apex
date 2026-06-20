// ===== Live end-to-end proof of the web -> field-service -> case loop =====
// (ES&O auto-schedule is enqueued + harmlessly swallowed since the engine isn't provisioned)

// --- seed parts inventory (idempotent-ish) ---
List<Product2> existing = [SELECT Id, Name FROM Product2 WHERE ProductCode = 'SWS-100' LIMIT 1];
Id partId;
if (existing.isEmpty()) {
    Product2 p = new Product2(Name = 'Steam Wand Seal', ProductCode = 'SWS-100', IsActive = true);
    insert p; partId = p.Id;
} else { partId = existing[0].Id; }

List<Schema.Location> vans = [SELECT Id FROM Location WHERE Name = 'Kwitko Tech Van 1' LIMIT 1];
Id vanId;
if (vans.isEmpty()) {
    Schema.Location v = new Schema.Location(Name = 'Kwitko Tech Van 1', IsInventoryLocation = true, LocationType = 'Van');
    insert v; vanId = v.Id;
} else { vanId = vans[0].Id; }

List<ProductItem> pis = [SELECT Id FROM ProductItem WHERE Product2Id = :partId AND LocationId = :vanId LIMIT 1];
if (pis.isEmpty()) {
    insert new ProductItem(Product2Id = partId, LocationId = vanId, QuantityOnHand = 4, QuantityUnitOfMeasure = 'Each');
} else { update new ProductItem(Id = pis[0].Id, QuantityOnHand = 4); }

// --- 1) customer books a visit on the web ---
FsBookVisit.Request r = new FsBookVisit.Request();
r.accountName = 'Blue Bottle Cafe (FSL Demo)';
r.email = 'demo@bluebottle.test'; r.verifiedEmail = 'demo@bluebottle.test';
r.preferredDate = Date.today().addDays(3).format();
r.problem = 'Steam wand leaking';
FsMaintenanceService.Result booked = FsBookVisit.run(new List<FsBookVisit.Request>{ r })[0];
System.debug('BOOK: ' + booked.success + ' | ' + booked.summary);

WorkOrder wo = [SELECT Id, CaseId, Status, AssetId FROM WorkOrder WHERE Subject = 'Maintenance visit'
                AND Account.Name = 'Blue Bottle Cafe (FSL Demo)' ORDER BY CreatedDate DESC LIMIT 1];
Id woId = wo.Id;

// --- 2) tech consumes a part that's on the van (in stock) ---
System.debug('CONSUME in-stock: ' + FieldPartsService.consumePart(woId, 'SWS-100', 1).summary);

// --- 3) tech needs a part NOT on the van -> request + return visit ---
List<Product2> grp = [SELECT Id FROM Product2 WHERE Name LIKE '%Grinder Burr%' LIMIT 1];
if (grp.isEmpty()) { Product2 g = new Product2(Name = 'Grinder Burr Set', ProductCode = 'GBS-200', IsActive = true); insert g; }
System.debug('CONSUME short: ' + FieldPartsService.consumePart(woId, 'GBS-200', 1).summary);

// --- 4) complete BOTH visits (initial + return) through the valid status path ---
Datetime s = Datetime.now().addDays(2);
for (ServiceAppointment sa : [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :woId]) {
    update new ServiceAppointment(Id = sa.Id, Status = 'Scheduled', SchedStartTime = s, SchedEndTime = s.addHours(1));
    update new ServiceAppointment(Id = sa.Id, Status = 'Dispatched');
    update new ServiceAppointment(Id = sa.Id, Status = 'In Progress');
    update new ServiceAppointment(Id = sa.Id, Status = 'Completed');
}

// --- final state ---
WorkOrder f = [SELECT Id, Status, CaseId FROM WorkOrder WHERE Id = :woId];
Case c = [SELECT Status, Resolution__c FROM Case WHERE Id = :f.CaseId];
Integer woli = [SELECT COUNT() FROM WorkOrderLineItem WHERE WorkOrderId = :woId];
Integer saCount = [SELECT COUNT() FROM ServiceAppointment WHERE ParentRecordId = :woId];
Integer consumed = [SELECT COUNT() FROM ProductConsumed WHERE WorkOrderId = :woId];
Integer reqs = [SELECT COUNT() FROM ProductRequest WHERE WorkOrderId = :woId];
Decimal stock = [SELECT QuantityOnHand FROM ProductItem WHERE Product2Id = :partId AND LocationId = :vanId].QuantityOnHand;
System.debug('=== RESULT ===');
System.debug('WO ' + woId + ' status=' + f.Status + ' | Case status=' + c.Status + ' resolution=' + c.Resolution__c);
System.debug('WOLI=' + woli + ' | SAs=' + saCount + ' | PartsConsumed=' + consumed + ' | PartsRequested=' + reqs + ' | VanStock(SWS-100)=' + stock);
