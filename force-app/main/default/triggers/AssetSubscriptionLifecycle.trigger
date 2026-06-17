/**
 * Asset trigger:
 *  1) RLM↔FSL coupling — keep MaintenancePlan + ServiceContract in lockstep on renew/cancel (update only).
 *  2) REAL-TIME subscription insights — recompute Account.Insights_Subscription_* the instant any
 *     subscription Asset is created/changed/cancelled/restored, so agents read live data (no daily lag).
 */
trigger AssetSubscriptionLifecycle on Asset (after insert, after update, after delete, after undelete) {
    if (Trigger.isUpdate) {
        AssetLifecycleCouplingService.syncFromAssetChanges(Trigger.new, Trigger.oldMap);
    }
    Set<Id> acctIds = new Set<Id>();
    for (Asset a : (Trigger.isDelete ? Trigger.old : Trigger.new)) {
        if (a.AccountId != null) acctIds.add(a.AccountId);
    }
    if (!acctIds.isEmpty()) SubscriptionInsightsService.recomputeForAccounts(acctIds);
}
