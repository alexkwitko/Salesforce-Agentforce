/**
 * AssetLifecycleCouplingService
 * Keeps the Field Service coverage layer in lockstep with the RLM subscription Asset.
 *
 * The RLM↔FSL renewal coupling is NOT automatic — this is the Flow/Apex you must build.
 * Chain: Asset → MaintenanceAsset → MaintenancePlan → (ServiceContractId) → ServiceContract.
 *
 * Fired from the Asset after-update trigger so it reacts to ANY subscription change —
 * the Subscription_Concierge agent today, or the Place Quote engine once provisioned
 * (when the engine is on, prefer triggering off AssetAction.Category; the field-change
 * detection below covers the Asset-direct path).
 *
 * Events (from Asset field changes):
 *   RENEW  = UsageEndDate extended (and not cancelled) → push the new end date onto the
 *            linked MaintenancePlan + ServiceContract.
 *   CANCEL = Status flips to Obsolete → end the MaintenancePlan (EndDate=today, stop
 *            auto-generation) + end the ServiceContract + cancel future ServiceAppointments.
 */
public without sharing class AssetLifecycleCouplingService {

    public static void syncFromAssetChanges(List<Asset> newList, Map<Id, Asset> oldMap) {
        Set<Id> renewIds = new Set<Id>();
        Set<Id> cancelIds = new Set<Id>();
        Map<Id, Date> assetNewEnd = new Map<Id, Date>();

        for (Asset a : newList) {
            Asset old = oldMap.get(a.Id);
            Boolean nowObsolete = a.Status == 'Obsolete' && old.Status != 'Obsolete';
            Boolean extended = a.UsageEndDate != null &&
                (old.UsageEndDate == null || a.UsageEndDate > old.UsageEndDate);
            if (nowObsolete) {
                cancelIds.add(a.Id);
            } else if (extended) {
                renewIds.add(a.Id);
                assetNewEnd.put(a.Id, a.UsageEndDate);
            }
        }
        if (renewIds.isEmpty() && cancelIds.isEmpty()) return;

        Set<Id> allAssetIds = new Set<Id>();
        allAssetIds.addAll(renewIds);
        allAssetIds.addAll(cancelIds);

        // Asset → linked Maintenance Plans
        Map<Id, Set<Id>> assetToPlans = new Map<Id, Set<Id>>();
        Set<Id> planIds = new Set<Id>();
        for (MaintenanceAsset ma : [
            SELECT AssetId, MaintenancePlanId FROM MaintenanceAsset
            WHERE AssetId IN :allAssetIds AND MaintenancePlanId != null
        ]) {
            if (!assetToPlans.containsKey(ma.AssetId)) assetToPlans.put(ma.AssetId, new Set<Id>());
            assetToPlans.get(ma.AssetId).add(ma.MaintenancePlanId);
            planIds.add(ma.MaintenancePlanId);
        }
        if (planIds.isEmpty()) return; // no FSL coverage on these assets — nothing to couple

        Map<Id, MaintenancePlan> plans = new Map<Id, MaintenancePlan>([
            SELECT Id, EndDate, ServiceContractId, DoesAutoGenerateWorkOrders
            FROM MaintenancePlan WHERE Id IN :planIds
        ]);

        Map<Id, MaintenancePlan> planUpdates = new Map<Id, MaintenancePlan>();
        Map<Id, ServiceContract> scUpdates = new Map<Id, ServiceContract>();
        Set<Id> cancelledPlanIds = new Set<Id>();
        Date today = Date.today();

        // RENEW — extend coverage to the subscription's new end date
        for (Id aid : renewIds) {
            if (!assetToPlans.containsKey(aid)) continue;
            Date newEnd = assetNewEnd.get(aid);
            for (Id pid : assetToPlans.get(aid)) {
                MaintenancePlan p = plans.get(pid);
                MaintenancePlan pu = planUpdates.containsKey(pid) ? planUpdates.get(pid) : new MaintenancePlan(Id = pid);
                pu.EndDate = newEnd;
                planUpdates.put(pid, pu);
                if (p.ServiceContractId != null) {
                    ServiceContract sc = scUpdates.containsKey(p.ServiceContractId)
                        ? scUpdates.get(p.ServiceContractId) : new ServiceContract(Id = p.ServiceContractId);
                    sc.EndDate = newEnd;
                    scUpdates.put(p.ServiceContractId, sc);
                }
            }
        }

        // CANCEL — stop the plan + end the contract
        for (Id aid : cancelIds) {
            if (!assetToPlans.containsKey(aid)) continue;
            for (Id pid : assetToPlans.get(aid)) {
                MaintenancePlan p = plans.get(pid);
                MaintenancePlan pu = planUpdates.containsKey(pid) ? planUpdates.get(pid) : new MaintenancePlan(Id = pid);
                pu.EndDate = today;
                pu.DoesAutoGenerateWorkOrders = false;
                planUpdates.put(pid, pu);
                cancelledPlanIds.add(pid);
                if (p.ServiceContractId != null) {
                    ServiceContract sc = scUpdates.containsKey(p.ServiceContractId)
                        ? scUpdates.get(p.ServiceContractId) : new ServiceContract(Id = p.ServiceContractId);
                    sc.EndDate = today;
                    scUpdates.put(p.ServiceContractId, sc);
                }
            }
        }

        if (!planUpdates.isEmpty()) update planUpdates.values();
        if (!scUpdates.isEmpty()) update scUpdates.values();

        // Cancel future service appointments for cancelled plans (best-effort)
        if (!cancelledPlanIds.isEmpty()) {
            Set<Id> woIds = new Set<Id>();
            for (WorkOrder w : [SELECT Id FROM WorkOrder WHERE MaintenancePlanId IN :cancelledPlanIds]) {
                woIds.add(w.Id);
            }
            if (!woIds.isEmpty()) {
                List<ServiceAppointment> toCancel = new List<ServiceAppointment>();
                for (ServiceAppointment sa : [
                    SELECT Id, Status FROM ServiceAppointment
                    WHERE ParentRecordId IN :woIds
                      AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
                      AND (SchedStartTime >= :Datetime.now() OR SchedStartTime = null)
                ]) {
                    sa.Status = 'Canceled';
                    toCancel.add(sa);
                }
                if (!toCancel.isEmpty()) Database.update(toCancel, false); // best-effort; don't block coupling
            }
        }
    }
}
