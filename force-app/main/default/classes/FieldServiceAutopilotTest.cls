@isTest
private class FieldServiceAutopilotTest {

    // Test data is isolated, so the handler's territory query only sees these two.
    @isTest
    static void territoryByNearestGeo() {
        OperatingHours oh = new OperatingHours(Name = 'AP Hours', TimeZone = 'America/Los_Angeles');
        insert oh;
        ServiceTerritory near = new ServiceTerritory(Name = 'AP Near', IsActive = true,
            OperatingHoursId = oh.Id, Latitude = 37.78, Longitude = -122.41);
        ServiceTerritory far = new ServiceTerritory(Name = 'AP Far', IsActive = true,
            OperatingHoursId = oh.Id, Latitude = 34.05, Longitude = -118.24);
        insert new List<ServiceTerritory>{ near, far };
        Account a = new Account(Name = 'AP Acct'); insert a;

        Test.startTest();
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = a.Id, Status = 'None', Subject = 'AP geo',
            Latitude = 37.79, Longitude = -122.40,
            EarliestStartTime = System.now().addDays(1), DueDate = System.now().addDays(6));
        insert sa;
        Test.stopTest();

        sa = [SELECT ServiceTerritoryId FROM ServiceAppointment WHERE Id = :sa.Id];
        System.assertEquals(near.Id, sa.ServiceTerritoryId, 'SA should map to nearest territory by geolocation');
    }

    @isTest
    static void territoryInheritFromWorkOrder() {
        OperatingHours oh = new OperatingHours(Name = 'AP Hours2', TimeZone = 'America/Los_Angeles');
        insert oh;
        ServiceTerritory t = new ServiceTerritory(Name = 'AP WO Terr', IsActive = true,
            OperatingHoursId = oh.Id, Latitude = 40.0, Longitude = -75.0);
        insert t;
        Account a = new Account(Name = 'AP Acct2'); insert a;
        WorkOrder wo = new WorkOrder(AccountId = a.Id, ServiceTerritoryId = t.Id); insert wo;

        Test.startTest();
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = wo.Id, Status = 'None', Subject = 'AP WO inherit',
            EarliestStartTime = System.now().addDays(1), DueDate = System.now().addDays(6));
        insert sa;
        Test.stopTest();

        sa = [SELECT ServiceTerritoryId FROM ServiceAppointment WHERE Id = :sa.Id];
        System.assertEquals(t.Id, sa.ServiceTerritoryId, 'SA should inherit territory from parent WorkOrder');
    }

    @isTest
    static void queueableRunsSafely() {
        Test.startTest();
        System.enqueueJob(new FieldServiceAutopilot.AutoScheduleQueueable(new List<Id>()));
        Test.stopTest();
        System.assert(true, 'empty queueable is a no-op');
    }
}
