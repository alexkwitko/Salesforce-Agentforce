@isTest
private class AssetServiceMetricsServiceTest {

    private static Asset makeAsset() {
        Account acc = new Account(Name = 'Metrics Cafe');
        insert acc;
        Asset a = new Asset(Name = 'Test Espresso Machine', AccountId = acc.Id,
                            SerialNumber = 'TST-001', Status = 'Installed');
        insert a;
        return a;
    }

    // Build a completed WO with explicit reported + service dates
    private static WorkOrder doneWO(Id assetId, Date reported, Date serviced) {
        return new WorkOrder(AssetId = assetId, Status = 'Completed',
                             Reported_Date__c = reported, Service_Date__c = serviced);
    }

    @isTest
    static void computesCallRateAndFtft() {
        Asset a = makeAsset();
        Date t = Date.today();
        // 4 completed calls in the last 12mo; one is a repeat (within 30 days of prior)
        List<WorkOrder> wos = new List<WorkOrder>{
            doneWO(a.Id, t.addDays(-300), t.addDays(-298)),
            doneWO(a.Id, t.addDays(-200), t.addDays(-197)),
            doneWO(a.Id, t.addDays(-100), t.addDays(-98)),
            doneWO(a.Id, t.addDays(-90),  t.addDays(-88)),   // repeat: ~10 days after prior
            new WorkOrder(AssetId = a.Id, Status = 'New')    // open, no service date
        };
        insert wos;

        Test.startTest();
        AssetServiceMetricsService.recalculate(new Set<Id>{ a.Id });
        Test.stopTest();

        Asset r = [SELECT Total_Service_Calls__c, Service_Calls_12mo__c, Call_Rate_Annual__c,
                          Fix_Right_First_Time__c, Repeat_Visits_12mo__c, Mean_Time_To_Repair_Days__c,
                          Last_Service_Date__c, Open_Work_Orders__c, Service_Metrics_Updated__c
                   FROM Asset WHERE Id = :a.Id];
        System.assertEquals(4, r.Total_Service_Calls__c, 'four completed calls');
        System.assertEquals(4, r.Service_Calls_12mo__c, 'all within 12mo');
        System.assertEquals(4.00, r.Call_Rate_Annual__c, 'call rate = 12mo calls');
        System.assertEquals(1, r.Repeat_Visits_12mo__c, 'one repeat within 30 days');
        System.assertEquals(75.0, r.Fix_Right_First_Time__c, 'FTFT = 3/4 = 75%');
        System.assertEquals(1, r.Open_Work_Orders__c, 'one open WO');
        System.assertEquals(t.addDays(-88), r.Last_Service_Date__c, 'latest service date');
        System.assertNotEquals(null, r.Mean_Time_To_Repair_Days__c, 'mttr computed');
        System.assertNotEquals(null, r.Service_Metrics_Updated__c, 'stamped');

        WorkOrder repeatWo = [SELECT Is_Repeat_Visit__c FROM WorkOrder
                              WHERE AssetId = :a.Id AND Service_Date__c = :t.addDays(-88)];
        System.assert(repeatWo.Is_Repeat_Visit__c, 'flagged as repeat');
    }

    @isTest
    static void getMetricsFromAllParents() {
        Asset a = makeAsset();
        WorkOrder wo = doneWO(a.Id, Date.today().addDays(-5), Date.today().addDays(-3));
        insert wo;
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = wo.Id,
            EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(2));
        insert sa;

        AssetServiceMetricsService.recalculate(new Set<Id>{ a.Id });

        Test.startTest();
        AssetServiceMetricsService.AssetMetrics fromAsset = AssetServiceMetricsService.getMetrics(a.Id);
        AssetServiceMetricsService.AssetMetrics fromWo    = AssetServiceMetricsService.getMetrics(wo.Id);
        AssetServiceMetricsService.AssetMetrics fromSa    = AssetServiceMetricsService.getMetrics(sa.Id);
        AssetServiceMetricsService.AssetMetrics refreshed = AssetServiceMetricsService.refreshMetrics(wo.Id);
        Test.stopTest();

        System.assert(fromAsset.hasAsset, 'asset resolves');
        System.assertEquals(a.Id, fromWo.assetId, 'WO -> asset');
        System.assertEquals(a.Id, fromSa.assetId, 'SA -> WO -> asset');
        System.assert(refreshed.hasAsset, 'refresh returns dto');
        System.assertEquals('Test Espresso Machine', fromAsset.assetName);
    }

    @isTest
    static void handlesNoAssetAndInvocableAndSchedule() {
        AssetServiceMetricsService.AssetMetrics none = AssetServiceMetricsService.getMetrics(null);
        System.assertEquals(false, none.hasAsset, 'null -> no asset');

        Asset a = makeAsset();
        Test.startTest();
        AssetServiceMetricsService.recalcInvocable(new List<Id>{ a.Id });
        AssetServiceMetricsService.recalculateAll();
        System.schedule('ASM Test', '0 0 3 * * ?', new AssetServiceMetricsSchedule());
        Test.stopTest();

        System.assertNotEquals(null,
            [SELECT Service_Metrics_Updated__c FROM Asset WHERE Id = :a.Id].Service_Metrics_Updated__c);
    }
}
