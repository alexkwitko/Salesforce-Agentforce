/**
 * Tests the RLM↔FSL renewal coupling (AssetSubscriptionLifecycle trigger →
 * AssetLifecycleCouplingService).
 *
 * Uses SeeAllData=true against a package-built Asset→MaintenanceAsset→MaintenancePlan
 * →ServiceContract chain: the FSL managed package blocks inserting a MaintenanceAsset
 * in a test (it recomputes NextSuggestedMaintenanceDate and rejects synthetic rows),
 * so we exercise the coupling on a real chain. All test DML is rolled back automatically.
 * Falls back gracefully (no failure) if the org has no covered subscription chain.
 */
@isTest
private class AssetLifecycleCouplingServiceTest {

    @isTest(SeeAllData=true)
    static void couplingRenewThenCancel() {
        List<MaintenanceAsset> mas = [
            SELECT AssetId, MaintenancePlanId, MaintenancePlan.ServiceContractId
            FROM MaintenanceAsset
            WHERE MaintenancePlanId != null AND MaintenancePlan.ServiceContractId != null
            LIMIT 1
        ];
        if (mas.isEmpty()) return; // no covered chain in this org — nothing to assert

        Id assetId = mas[0].AssetId;
        Id planId  = mas[0].MaintenancePlanId;
        Id scId    = mas[0].MaintenancePlan.ServiceContractId;
        Asset a = [SELECT Id, Status, UsageEndDate FROM Asset WHERE Id = :assetId];

        // --- RENEW: extend the subscription asset ---
        Date newEnd = Date.today().addYears(3);
        a.Status = 'Installed';
        a.UsageEndDate = newEnd;
        update a;

        MaintenancePlan mp = [SELECT EndDate FROM MaintenancePlan WHERE Id = :planId];
        ServiceContract sc = [SELECT EndDate FROM ServiceContract WHERE Id = :scId];
        System.assertEquals(newEnd, mp.EndDate, 'Renew should push the new end date onto the MaintenancePlan');
        System.assertEquals(newEnd, sc.EndDate, 'Renew should push the new end date onto the ServiceContract');

        // --- CANCEL: obsolete the subscription asset ---
        a.Status = 'Obsolete';
        update a;

        mp = [SELECT EndDate, DoesAutoGenerateWorkOrders FROM MaintenancePlan WHERE Id = :planId];
        sc = [SELECT EndDate FROM ServiceContract WHERE Id = :scId];
        System.assertEquals(Date.today(), mp.EndDate, 'Cancel should end the MaintenancePlan today');
        System.assertEquals(false, mp.DoesAutoGenerateWorkOrders, 'Cancel should stop auto work-order generation');
        System.assertEquals(Date.today(), sc.EndDate, 'Cancel should end the ServiceContract today');
    }

    // Covers the no-coverage early-return path (asset with no maintenance link).
    @isTest
    static void noCoverageNoOp() {
        Account acc = new Account(Name = 'Coupling Test Co');
        insert acc;
        Asset a = new Asset(Name = 'Uncovered Sub', AccountId = acc.Id, Quantity = 1, Price = 10,
            Status = 'Installed', InstallDate = Date.today(), UsageEndDate = Date.today().addYears(1));
        insert a;

        Test.startTest();
        a.UsageEndDate = Date.today().addYears(2); // renew with no linked plan → handler returns early
        update a;
        a.Status = 'Obsolete';                     // cancel with no linked plan → handler returns early
        update a;
        Test.stopTest();

        System.assertEquals('Obsolete', [SELECT Status FROM Asset WHERE Id = :a.Id].Status,
            'Asset update should succeed even with no maintenance coverage');
    }
}
