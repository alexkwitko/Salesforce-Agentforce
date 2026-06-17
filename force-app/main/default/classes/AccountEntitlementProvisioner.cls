/**
 * AccountEntitlementProvisioner — after-insert handler that gives every new customer (Person Account)
 * a "Standard Support" Entitlement tied to the active SLA process, so Cases opened for that customer
 * instantiate SLA milestones (via CaseEntitlementStamp). Without this, only the back-filled accounts
 * had entitlements and new customers would get no SLA. Bulk-safe; idempotent; no-ops if the SLA process
 * or default business hours can't be found.
 */
public without sharing class AccountEntitlementProvisioner {

    public static void provision(List<Account> accts) {
        if (accts == null || accts.isEmpty()) return;

        // Only customer person accounts that don't already have a Standard Support entitlement.
        Set<Id> candidateIds = new Set<Id>();
        for (Account a : accts) {
            if (a != null && a.Id != null && a.IsPersonAccount == true) candidateIds.add(a.Id);
        }
        if (candidateIds.isEmpty()) return;

        for (AggregateResult ar : [
            SELECT AccountId aid FROM Entitlement
            WHERE Name = 'Standard Support' AND AccountId IN :candidateIds GROUP BY AccountId
        ]) {
            candidateIds.remove((Id) ar.get('aid'));
        }
        if (candidateIds.isEmpty()) return;

        // Resolve the active SLA process + default business hours (no hardcoded ids → portable).
        Id slaProcessId, businessHoursId;
        try {
            List<SlaProcess> sps = [
                SELECT Id FROM SlaProcess
                WHERE SobjectType = 'Case' AND IsActive = true
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (sps.isEmpty()) return;
            slaProcessId = sps[0].Id;
            List<BusinessHours> bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true AND IsActive = true LIMIT 1];
            businessHoursId = bh.isEmpty() ? null : bh[0].Id;
        } catch (Exception e) {
            System.debug('AccountEntitlementProvisioner lookup skipped: ' + e.getMessage());
            return;
        }

        Date today = Date.today();
        List<Entitlement> toIns = new List<Entitlement>();
        for (Id aId : candidateIds) {
            toIns.add(new Entitlement(
                Name = 'Standard Support',
                AccountId = aId,
                SlaProcessId = slaProcessId,
                BusinessHoursId = businessHoursId,
                StartDate = today,
                EndDate = today.addYears(10)
            ));
        }
        try {
            insert toIns;
        } catch (Exception e) {
            System.debug('AccountEntitlementProvisioner insert skipped: ' + e.getMessage());
        }
    }
}
