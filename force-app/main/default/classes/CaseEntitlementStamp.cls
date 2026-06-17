/**
 * CaseEntitlementStamp — before-insert handler that attaches the customer's "Standard Support"
 * Entitlement to a new Case so the SLA EntitlementProcess instantiates CaseMilestone rows
 * (First Response / Escalate / Close). Without an EntitlementId on the Case, the active SLA
 * process tracks nothing — this is what turns the dormant SLA into a live first-response clock.
 * Bulk-safe; only stamps when the Case has an Account and no Entitlement yet (guest cases skipped).
 */
public without sharing class CaseEntitlementStamp {

    public static void stamp(List<Case> cases) {
        if (cases == null || cases.isEmpty()) return;
        Set<Id> acctIds = new Set<Id>();
        for (Case c : cases) {
            if (c != null && c.EntitlementId == null && c.AccountId != null) acctIds.add(c.AccountId);
        }
        if (acctIds.isEmpty()) return;

        Map<Id, Id> entByAccount = new Map<Id, Id>();
        try {
            for (Entitlement e : [
                SELECT Id, AccountId
                FROM Entitlement
                WHERE AccountId IN :acctIds
                  AND Name = 'Standard Support'
                  AND StartDate <= TODAY
                  AND (EndDate = null OR EndDate >= TODAY)
                ORDER BY CreatedDate DESC
            ]) {
                if (!entByAccount.containsKey(e.AccountId)) entByAccount.put(e.AccountId, e.Id);
            }
        } catch (Exception ex) {
            System.debug('CaseEntitlementStamp lookup skipped: ' + ex.getMessage());
            return;
        }

        for (Case c : cases) {
            if (c.EntitlementId == null && c.AccountId != null && entByAccount.containsKey(c.AccountId)) {
                c.EntitlementId = entByAccount.get(c.AccountId);
            }
        }
    }
}
