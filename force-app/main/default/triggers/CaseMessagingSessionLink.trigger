trigger CaseMessagingSessionLink on Case (before insert, after insert) {
    if (Trigger.isBefore && Trigger.isInsert) {
        // Map Category__c -> Case record type for every creation path (agent, fix tools, future intake).
        CaseRecordTypeStamp.stamp(Trigger.new);
        // Attach the customer's Standard Support entitlement so the SLA process instantiates milestones
        // (First Response / Escalate / Close). Requires Case.EntitlementId provisioned + FLS granted
        // (Kwitko_Entitlement_Access perm set) — both done.
        CaseEntitlementStamp.stamp(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isInsert) {
        CaseMessagingSessionLinker.afterInsert(Trigger.new);
    }
}
