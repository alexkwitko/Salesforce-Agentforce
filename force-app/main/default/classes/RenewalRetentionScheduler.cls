/**
 * RenewalRetentionScheduler — autonomous daily sweep of the subscription book.
 * Each run finds subscriptions due within the window and creates a deduped
 * follow-up Task per account with the churn-driven next-best action (the same
 * recommendation logic the Renewal_Retention agent uses). Deterministic — it
 * builds the rep worklist; humans (or the agent) execute the renew/save.
 *
 * Schedule: System.schedule('Renewal Retention Daily Sweep','0 0 7 * * ?', new RenewalRetentionScheduler());
 */
public without sharing class RenewalRetentionScheduler implements Schedulable {

    public Integer windowDays = 30;

    public void execute(SchedulableContext sc) {
        sweep(windowDays);
    }

    /** Returns the number of new worklist tasks created. */
    public static Integer sweep(Integer windowDays) {
        Integer days = (windowDays == null || windowDays <= 0) ? 30 : windowDays;
        Date cutoff = Date.today().addDays(days);

        List<Asset> due = [
            SELECT AccountId, Account.Name, Account.Churn_Risk_Tier__c, Quantity, UsageEndDate
            FROM Asset
            WHERE Status = 'Installed' AND Product2.Family = 'Subscription'
                  AND UsageEndDate != null AND UsageEndDate <= :cutoff
        ];
        if (due.isEmpty()) return 0;

        Set<Id> acctIds = new Set<Id>();
        for (Asset a : due) if (a.AccountId != null) acctIds.add(a.AccountId);

        // Dedupe: skip accounts that already have an open renewal-sweep task
        Set<Id> already = new Set<Id>();
        for (Task t : [SELECT WhatId FROM Task WHERE Subject LIKE 'Renewal due:%' AND Status != 'Completed' AND WhatId IN :acctIds]) {
            already.add(t.WhatId);
        }

        List<Task> toCreate = new List<Task>();
        Set<Id> seen = new Set<Id>();
        for (Asset a : due) {
            if (a.AccountId == null || already.contains(a.AccountId) || seen.contains(a.AccountId)) continue;
            seen.add(a.AccountId);
            String tier = a.Account.Churn_Risk_Tier__c;
            Integer d = Date.today().daysBetween(a.UsageEndDate);
            toCreate.add(new Task(
                Subject = 'Renewal due: ' + a.Account.Name,
                WhatId = a.AccountId,
                Status = 'Open',
                Priority = (tier == 'A') ? 'High' : 'Normal',
                ActivityDate = a.UsageEndDate,
                Description = 'Subscription renews in ' + d + ' days (churn tier ' + tier + '). Recommended: '
                    + RenewalBookService.recommend(tier, a.Quantity)
            ));
        }
        if (!toCreate.isEmpty()) insert toCreate;
        return toCreate.size();
    }
}
