/**
 * CaseRecordTypeStamp — before-insert handler that maps Case.Category__c to the right Case record type
 * (Order Issue / Return-Refund / Billing / General) when RecordTypeId isn't already set. Centralizing
 * this in the trigger means every case-creation path (CaseService, StoreCreditService, ExchangeService,
 * future Email/Web intake, …) gets categorized record types without each class having to know the mapping.
 * Defensive: only stamps when RecordTypeId is null and a matching active record type exists.
 */
public without sharing class CaseRecordTypeStamp {

    private static Map<String, Id> rtByDevName;

    public static void stamp(List<Case> cases) {
        if (cases == null || cases.isEmpty()) return;
        Boolean anyNeeded = false;
        for (Case c : cases) { if (c != null && c.RecordTypeId == null) { anyNeeded = true; break; } }
        if (!anyNeeded) return;

        if (rtByDevName == null) {
            rtByDevName = new Map<String, Id>();
            try {
                for (RecordType rt : [SELECT Id, DeveloperName FROM RecordType
                                      WHERE SObjectType = 'Case' AND IsActive = true]) {
                    rtByDevName.put(rt.DeveloperName, rt.Id);
                }
            } catch (Exception e) {
                System.debug('CaseRecordTypeStamp lookup skipped: ' + e.getMessage());
                return;
            }
        }

        for (Case c : cases) {
            if (c.RecordTypeId != null) continue;
            Id rtId = rtByDevName.get(devNameForCategory(c.Category__c));
            if (rtId != null) c.RecordTypeId = rtId;
        }
    }

    private static String devNameForCategory(String category) {
        String c = String.isBlank(category) ? '' : category.trim().toLowerCase();
        if (c == 'order' || c == 'shipping') return 'Order_Issue';
        if (c == 'returns' || c == 'refund') return 'Return_Refund';
        if (c == 'billing') return 'Billing';
        return 'General'; // Product, Account, Escalation, blank, or anything unmapped
    }
}
