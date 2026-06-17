/**
 * SubscriptionInsightsService — keeps the unified profile SUBSCRIPTION-AWARE in REAL TIME.
 *
 * recomputeForAccounts() is fired SYNCHRONOUSLY from the Asset trigger on every
 * insert/update/delete/undelete, so Account.Insights_Subscription_* is always current
 * the instant a subscription is provisioned, amended, renewed, or cancelled — the agents
 * read live data, never a daily snapshot. computeAll() (Schedulable) is a nightly
 * reconciliation safety-net only.
 *
 * Account already flows into Data Cloud (it's a DMO in the unified profile), so these
 * fields become unified-profile attributes once mapped on the Account DMO.
 */
public without sharing class SubscriptionInsightsService implements Schedulable {

    // Nightly reconcile safety-net; the live path is the Asset trigger.
    public void execute(SchedulableContext sc) { computeAll(); }

    public static Integer computeAll() {
        Set<Id> acctIds = new Set<Id>();
        for (AggregateResult ar : [
            SELECT AccountId aid FROM Asset
            WHERE Status = 'Installed' AND Product2.Family = 'Subscription' AND AccountId != null
            GROUP BY AccountId
        ]) acctIds.add((Id) ar.get('aid'));
        for (Account a : [SELECT Id FROM Account WHERE Insights_Has_Subscription__c = true]) acctIds.add(a.Id);
        return recomputeForAccounts(acctIds);
    }

    /** Real-time recompute for a specific set of accounts (called from the Asset trigger). */
    public static Integer recomputeForAccounts(Set<Id> acctIds) {
        if (acctIds == null || acctIds.isEmpty()) return 0;
        Map<Id, Decimal> value = new Map<Id, Decimal>();
        Map<Id, Integer> count = new Map<Id, Integer>();
        Map<Id, Date> nextRenewal = new Map<Id, Date>();

        for (Asset a : [
            SELECT AccountId, Quantity, Price, UsageEndDate FROM Asset
            WHERE Status = 'Installed' AND Product2.Family = 'Subscription' AND AccountId IN :acctIds
        ]) {
            Decimal line = (a.Quantity == null ? 0 : a.Quantity) * (a.Price == null ? 0 : a.Price);
            value.put(a.AccountId, (value.containsKey(a.AccountId) ? value.get(a.AccountId) : 0) + line);
            count.put(a.AccountId, (count.containsKey(a.AccountId) ? count.get(a.AccountId) : 0) + 1);
            if (a.UsageEndDate != null) {
                Date cur = nextRenewal.get(a.AccountId);
                if (cur == null || a.UsageEndDate < cur) nextRenewal.put(a.AccountId, a.UsageEndDate);
            }
        }

        List<Account> toUpdate = new List<Account>();
        for (Id aid : acctIds) {
            Boolean has = value.containsKey(aid);
            toUpdate.add(new Account(
                Id = aid,
                Insights_Subscription_Value__c = has ? value.get(aid).setScale(2) : 0,
                Insights_Subscription_Count__c = has ? count.get(aid) : 0,
                Insights_Next_Renewal__c = has ? nextRenewal.get(aid) : null,
                Insights_Has_Subscription__c = has
            ));
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        return toUpdate.size();
    }
}
