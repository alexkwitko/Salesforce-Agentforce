@isTest
private class FieldServiceLoopTest {

    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'Loop Cafe');
        insert a;
        insert new Contact(FirstName = 'Loop', LastName = 'Owner', Email = 'loop@cafe.test', AccountId = a.Id);
        insert new Asset(Name = 'Loop Espresso Machine', AccountId = a.Id, Status = 'Installed', SerialNumber = 'LP-1');
        insert new ServiceContract(Name = 'Loop Care', AccountId = a.Id,
            StartDate = Date.today().addDays(-30), EndDate = Date.today().addDays(300));
        insert new Entitlement(Name = 'Loop SLA', AccountId = a.Id,
            StartDate = Date.today().addDays(-30), EndDate = Date.today().addDays(300));
        insert new WorkType(Name = 'Annual Maintenance Visit', EstimatedDuration = 60, DurationType = 'Minutes');

        // parts inventory
        Product2 part = new Product2(Name = 'Steam Wand Seal', ProductCode = 'SWS-100', IsActive = true);
        insert part;
        Schema.Location van = new Schema.Location(Name = 'Tech Van A', IsInventoryLocation = true, LocationType = 'Van');
        insert van;
        insert new ProductItem(Product2Id = part.Id, LocationId = van.Id,
            QuantityOnHand = 5, QuantityUnitOfMeasure = 'Each');
    }

    static Id accId() { return [SELECT Id FROM Account WHERE Name = 'Loop Cafe' LIMIT 1].Id; }

    // Walk an SA through the FSL-enforced status path to Completed (Scheduled needs sched start/end).
    static void completeSA(Id saId) {
        Datetime s = Datetime.now().addDays(2);
        update new ServiceAppointment(Id = saId, Status = 'Scheduled', SchedStartTime = s, SchedEndTime = s.addHours(1));
        update new ServiceAppointment(Id = saId, Status = 'Dispatched');
        update new ServiceAppointment(Id = saId, Status = 'In Progress');
        update new ServiceAppointment(Id = saId, Status = 'Completed');
    }

    static FsBookVisit.Request bookReq() {
        FsBookVisit.Request r = new FsBookVisit.Request();
        r.email = 'loop@cafe.test'; r.verifiedEmail = 'loop@cafe.test';
        r.preferredDate = Date.today().addDays(3).format();
        r.problem = 'Grinder making noise';
        return r;
    }

    @isTest
    static void bookCreatesCaseChain() {
        FieldServiceAutopilot.skipSchedule = true;
        Test.startTest();
        List<FsMaintenanceService.Result> res = FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        Test.stopTest();

        System.assert(res[0].success, res[0].summary);
        Case c = [SELECT Id, Status, AssetId, AccountId, EntitlementId FROM Case WHERE AccountId = :accId() LIMIT 1];
        System.assertEquals('New', c.Status);
        System.assertNotEquals(null, c.AssetId, 'asset linked to case');
        WorkOrder wo = [SELECT Id, CaseId, AssetId, ServiceContractId, EntitlementId FROM WorkOrder WHERE CaseId = :c.Id LIMIT 1];
        System.assertEquals(c.Id, wo.CaseId, 'WO on the case');
        System.assertNotEquals(null, wo.ServiceContractId, 'contract linked');
        System.assertEquals(1, [SELECT COUNT() FROM WorkOrderLineItem WHERE WorkOrderId = :wo.Id], 'one WOLI');
        ServiceAppointment sa = [SELECT Visit_Reason__c, Status FROM ServiceAppointment WHERE ParentRecordId = :wo.Id LIMIT 1];
        System.assertEquals('Initial Visit', sa.Visit_Reason__c);
    }

    @isTest
    static void caseFollowsWorkOrderStatus() {
        FieldServiceAutopilot.skipSchedule = true;
        FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        WorkOrder wo = [SELECT Id, CaseId FROM WorkOrder WHERE CaseId != null LIMIT 1];

        Test.startTest();
        update new WorkOrder(Id = wo.Id, Status = 'In Progress');
        System.assertEquals('Working', [SELECT Status FROM Case WHERE Id = :wo.CaseId].Status, 'WO In Progress -> Case Working');
        update new WorkOrder(Id = wo.Id, Status = 'Completed');
        Test.stopTest();
        System.assertEquals('Closed', [SELECT Status FROM Case WHERE Id = :wo.CaseId].Status, 'WO Completed -> Case Closed');
    }

    @isTest
    static void saCompletionRollsUpAndReturnVisitKeepsOpen() {
        FieldServiceAutopilot.skipSchedule = true;
        FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        WorkOrder wo = [SELECT Id, CaseId FROM WorkOrder WHERE CaseId != null LIMIT 1];
        ServiceAppointment sa1 = [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :wo.Id LIMIT 1];

        Test.startTest();
        // add a return visit -> WO must NOT auto-complete while it's open
        FieldServiceFollowUp.Result fu = FieldServiceFollowUp.create(wo.Id, 'Return - Additional Issue', null, 'extra issue');
        System.assert(fu.success);
        completeSA(sa1.Id);
        System.assertNotEquals('Completed', [SELECT Status FROM WorkOrder WHERE Id = :wo.Id].Status,
            'WO stays open while a return visit is pending');
        // complete the return visit -> now WO completes -> Case closes
        completeSA(fu.serviceAppointmentId);
        Test.stopTest();

        System.assertEquals('Completed', [SELECT Status FROM WorkOrder WHERE Id = :wo.Id].Status);
        System.assertEquals('Closed', [SELECT Status FROM Case WHERE Id = :wo.CaseId].Status);
        System.assertEquals(2, [SELECT COUNT() FROM ServiceAppointment WHERE ParentRecordId = :wo.Id]);
    }

    @isTest
    static void partsConsumeFromStock() {
        FieldServiceAutopilot.skipSchedule = true;
        FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        Id woId = [SELECT Id FROM WorkOrder WHERE CaseId != null LIMIT 1].Id;

        Test.startTest();
        FieldPartsService.Result req = FieldPartsService.requirePart(woId, 'SWS-100', 1);
        FieldPartsService.Result con = FieldPartsService.consumePart(woId, 'SWS-100', 2);
        Test.stopTest();

        System.assert(req.success, req.summary);
        System.assert(con.success, con.summary);
        System.assertEquals(1, [SELECT COUNT() FROM ProductRequired WHERE ParentRecordId = :woId]);
        System.assertEquals(1, [SELECT COUNT() FROM ProductConsumed WHERE WorkOrderId = :woId]);
        System.assertEquals(3, [SELECT QuantityOnHand FROM ProductItem WHERE Product2Id IN (SELECT Id FROM Product2 WHERE ProductCode='SWS-100')].QuantityOnHand);
    }

    @isTest
    static void partsShortRaisesRequestAndReturnVisit() {
        FieldServiceAutopilot.skipSchedule = true;
        FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        Id woId = [SELECT Id FROM WorkOrder WHERE CaseId != null LIMIT 1].Id;
        // drain stock
        update new ProductItem(Id = [SELECT Id FROM ProductItem LIMIT 1].Id, QuantityOnHand = 0);

        Test.startTest();
        FieldPartsService.Result con = FieldPartsService.consumePart(woId, 'SWS-100', 1);
        Test.stopTest();

        System.assert(con.success, con.summary);
        System.assertEquals(1, [SELECT COUNT() FROM ProductRequest WHERE WorkOrderId = :woId]);
        System.assertEquals(1, [SELECT COUNT() FROM ProductRequestLineItem]);
        System.assertEquals(2, [SELECT COUNT() FROM ServiceAppointment WHERE ParentRecordId = :woId], 'return visit added');
    }

    @isTest
    static void bookSlotSchedulesAppointment() {
        OperatingHours oh = new OperatingHours(Name = 'Test OH', TimeZone = 'America/New_York');
        insert oh;
        ServiceTerritory terr = new ServiceTerritory(Name = 'Test Terr', OperatingHoursId = oh.Id, IsActive = true);
        insert terr;
        ServiceResource sr = new ServiceResource(Name = 'Test Tech', RelatedRecordId = UserInfo.getUserId(),
            ResourceType = 'T', IsActive = true);
        insert sr;
        insert new ServiceTerritoryMember(ServiceTerritoryId = terr.Id, ServiceResourceId = sr.Id,
            TerritoryType = 'P', EffectiveStartDate = Date.today().addDays(-1));

        Account a = [SELECT Id FROM Account WHERE Name = 'Loop Cafe' LIMIT 1];
        WorkOrder wo = new WorkOrder(AccountId = a.Id, Status = 'New', ServiceTerritoryId = terr.Id);
        insert wo;
        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = wo.Id, ServiceTerritoryId = terr.Id,
            Status = 'None', EarliestStartTime = Datetime.now().addDays(1), DueDate = Datetime.now().addDays(8));
        insert sa;

        Test.startTest();
        // exercise the engine query paths (callout itself is test-guarded)
        System.assertEquals(false, FieldServiceAutopilot.candidateSchedule(sa.Id), 'no policy in test -> false');
        System.assertEquals(0, FieldServiceAutopilot.realSlots(sa.Id).size(), 'real slots test-guarded -> empty');
        // sliceInterval turns a real availability interval into AM/PM windows
        Datetime ws = Datetime.newInstance(Date.today().addDays(2), Time.newInstance(8, 0, 0, 0));
        System.assert(FieldServiceSlots.sliceInterval(ws, ws.addHours(9)).size() >= 1, 'slices AM/PM');

        Boolean booked = FieldServiceAutopilot.bookSlot(sa.Id, Datetime.now().addDays(1), 60);
        // candidateSchedule on a territory-less SA returns false before any callout
        WorkOrder wo2 = new WorkOrder(AccountId = a.Id, Status = 'New');
        insert wo2;
        ServiceAppointment saNoTerr = new ServiceAppointment(ParentRecordId = wo2.Id, Status = 'None',
            EarliestStartTime = Datetime.now().addDays(1), DueDate = Datetime.now().addDays(8));
        insert saNoTerr;
        System.assertEquals(false, FieldServiceAutopilot.candidateSchedule(saNoTerr.Id), 'no territory -> false');
        System.assertEquals(0, FieldServiceAutopilot.realSlots(null).size(), 'null -> empty');
        Test.stopTest();

        System.assert(booked, 'bookSlot should schedule');
        ServiceAppointment r = [SELECT Status, SchedStartTime, SchedEndTime FROM ServiceAppointment WHERE Id = :sa.Id];
        System.assertEquals('Scheduled', r.Status);
        System.assertNotEquals(null, r.SchedStartTime);
        System.assertEquals(1, [SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id]);
    }

    @isTest
    static void slotsAndInvocablesAndGate() {
        FieldServiceAutopilot.skipSchedule = true;
        // slots
        System.assertEquals(10, FieldServiceSlots.generate(5).size(), '5 days x 2 windows');
        // get_slots: no account resolvable
        FsGetSlots.Request unknown = new FsGetSlots.Request();
        unknown.email = 'nobody@nowhere.test';
        System.assertEquals(false, FsGetSlots.run(new List<FsGetSlots.Request>{ unknown })[0].success, 'no account');

        // get_slots: account found but no open visit yet
        FsGetSlots.Request gs = new FsGetSlots.Request();
        gs.email = 'loop@cafe.test'; gs.verifiedEmail = 'loop@cafe.test'; gs.daysAhead = 3;
        System.assert(FsGetSlots.run(new List<FsGetSlots.Request>{ gs })[0].success);

        // identity gate
        FsBookVisit.Request bad = bookReq(); bad.verifiedEmail = null;
        System.assertEquals(false, FsBookVisit.run(new List<FsBookVisit.Request>{ bad })[0].success);

        // invocable wrappers
        FsBookVisit.run(new List<FsBookVisit.Request>{ bookReq() });
        // get_slots: now an open visit exists -> exercises the realSlots branch
        System.assert(FsGetSlots.run(new List<FsGetSlots.Request>{ gs })[0].success);
        Id woId = [SELECT Id FROM WorkOrder WHERE CaseId != null LIMIT 1].Id;
        FsAddRequiredPart.Request ar = new FsAddRequiredPart.Request();
        ar.workOrderId = woId; ar.productCode = 'SWS-100'; ar.quantity = 1;
        System.assert(FsAddRequiredPart.run(new List<FsAddRequiredPart.Request>{ ar })[0].success);
        FsConsumePart.Request cr = new FsConsumePart.Request();
        cr.workOrderId = woId; cr.productCode = 'SWS-100'; cr.quantity = 1;
        System.assert(FsConsumePart.run(new List<FsConsumePart.Request>{ cr })[0].success);
        FieldServiceFollowUp.Request fr = new FieldServiceFollowUp.Request();
        fr.workOrderId = woId; fr.reason = 'Return - Parts Needed';
        System.assert(FieldServiceFollowUp.run(new List<FieldServiceFollowUp.Request>{ fr })[0].success);
    }
}
