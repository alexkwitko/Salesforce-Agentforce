/**
 * CaseServicePanelController — data for the caseServicePanel LWC on the Case record page.
 * Surfaces the SLA milestones (with target/violation), the customer's entitlement + service contract,
 * and order/account context in one "service cockpit" card. Defensive: entitlement fields are FLS-gated
 * (Kwitko_Entitlement_Access perm set), so it degrades gracefully if the running user lacks access.
 */
public with sharing class CaseServicePanelController {

    public class MilestoneInfo {
        @AuraEnabled public String name;
        @AuraEnabled public Datetime targetDate;
        @AuraEnabled public Datetime completionDate;
        @AuraEnabled public Boolean isCompleted;
        @AuraEnabled public Boolean isViolated;
        @AuraEnabled public String status;      // Completed | Violated | In Progress
        @AuraEnabled public String variant;     // success | error | inverse (for badge/theme)
    }

    public class ServiceInfo {
        @AuraEnabled public Boolean hasEntitlement = false;
        @AuraEnabled public String entitlementName;
        @AuraEnabled public String slaProcessName;
        @AuraEnabled public Date entStartDate;
        @AuraEnabled public Date entEndDate;
        @AuraEnabled public Boolean hasContract = false;
        @AuraEnabled public String contractName;
        @AuraEnabled public String contractStatus;
        @AuraEnabled public Date contractEndDate;
        @AuraEnabled public Id contractId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public Id orderId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id accountId;
        @AuraEnabled public List<MilestoneInfo> milestones = new List<MilestoneInfo>();
        @AuraEnabled public Boolean hasMilestones = false;
    }

    @AuraEnabled(cacheable=true)
    public static ServiceInfo getServiceInfo(Id caseId) {
        ServiceInfo si = new ServiceInfo();

        // Case + account + order + entitlement + contract. Entitlement.* is FLS-gated → try rich, fall back.
        SObject c;
        Boolean gotEntitlement = false;
        try {
            c = Database.query(
                'SELECT Id, AccountId, Account.Name, Order__c, Order__r.OrderNumber, EntitlementId, ' +
                'Entitlement.Name, Entitlement.StartDate, Entitlement.EndDate, Entitlement.SlaProcess.Name, ' +
                'Entitlement.ServiceContractId, Entitlement.ServiceContract.Name, Entitlement.ServiceContract.Status, Entitlement.ServiceContract.EndDate ' +
                'FROM Case WHERE Id = :caseId'
            );
            gotEntitlement = true;
        } catch (Exception e) {
            c = [SELECT Id, AccountId, Account.Name, Order__c, Order__r.OrderNumber FROM Case WHERE Id = :caseId];
        }

        si.accountId = (Id) c.get('AccountId');
        si.accountName = c.getSObject('Account') == null ? null : (String) c.getSObject('Account').get('Name');
        si.orderId = (Id) c.get('Order__c');
        if (c.getSObject('Order__r') != null) si.orderNumber = (String) c.getSObject('Order__r').get('OrderNumber');

        if (gotEntitlement && c.get('EntitlementId') != null) {
            SObject ent = c.getSObject('Entitlement');
            si.hasEntitlement = true;
            si.entitlementName = (String) ent.get('Name');
            si.entStartDate = (Date) ent.get('StartDate');
            si.entEndDate = (Date) ent.get('EndDate');
            if (ent.getSObject('SlaProcess') != null) si.slaProcessName = (String) ent.getSObject('SlaProcess').get('Name');
            if (ent.get('ServiceContractId') != null && ent.getSObject('ServiceContract') != null) {
                SObject sc = ent.getSObject('ServiceContract');
                si.hasContract = true;
                si.contractId = (Id) ent.get('ServiceContractId');
                si.contractName = (String) sc.get('Name');
                si.contractStatus = (String) sc.get('Status');
                si.contractEndDate = (Date) sc.get('EndDate');
            }
        }

        for (CaseMilestone m : [
            SELECT MilestoneType.Name, TargetDate, CompletionDate, IsCompleted, IsViolated
            FROM CaseMilestone WHERE CaseId = :caseId ORDER BY TargetDate ASC
        ]) {
            MilestoneInfo mi = new MilestoneInfo();
            mi.name = m.MilestoneType.Name;
            mi.targetDate = m.TargetDate;
            mi.completionDate = m.CompletionDate;
            mi.isCompleted = m.IsCompleted;
            mi.isViolated = m.IsViolated;
            if (m.IsCompleted) { mi.status = 'Completed'; mi.variant = 'success'; }
            else if (m.IsViolated) { mi.status = 'Violated'; mi.variant = 'error'; }
            else { mi.status = 'In Progress'; mi.variant = 'inverse'; }
            si.milestones.add(mi);
        }
        si.hasMilestones = !si.milestones.isEmpty();
        return si;
    }
}
