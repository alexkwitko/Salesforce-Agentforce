/**
 * Builds a rich, pre-materialized "customer brief" string per Account — profile 360 + last order
 * + items + open cases + upcoming service visits + active subscriptions — so a chat session can
 * stamp it onto MessagingSession.Customer_Brief__c and the Concierge reads it via a linked variable
 * for FREE (no Agentforce actions / no Flex Credits) instead of calling get_agent_context /
 * get_order_status / get_maintenance_visits / get_subscriptions live.
 *
 * Bulk-safe (all queries are IN :accountIds). Read-only. Used by MessagingSessionBrandStamp at
 * session before-insert. Defensive: any failure returns what it has so far / empty.
 */
public without sharing class CustomerBriefBuilder {

    /** Returns Account.Id -> brief string for the given accounts. */
    public static Map<Id,String> briefsByAccount(Set<Id> accountIds) {
        Map<Id,String> out = new Map<Id,String>();
        if (accountIds == null || accountIds.isEmpty()) return out;
        try {
            // --- Profile 360 (already-materialized Account fields) ---
            Map<Id,Account> accById = new Map<Id,Account>([
                SELECT Id, Data_Cloud_Segment__c, Insights_LTV__c, Predicted_LTV__c,
                       Brands_Purchased__c, Is_Multi_Brand__c, Churn_Risk_Tier__c
                FROM Account WHERE Id IN :accountIds
            ]);

            // --- Last order per account (most recent) ---
            Map<Id,Order> lastOrderByAcct = new Map<Id,Order>();
            for (Order o : [
                SELECT Id, AccountId, OrderNumber, Status, Woo_Order_Total__c, Tracking_Number__c, CreatedDate
                FROM Order WHERE AccountId IN :accountIds ORDER BY CreatedDate DESC
            ]) {
                if (!lastOrderByAcct.containsKey(o.AccountId)) lastOrderByAcct.put(o.AccountId, o);
            }
            // Items for those last orders
            Map<Id,List<String>> itemsByOrder = new Map<Id,List<String>>();
            Set<Id> lastOrderIds = new Set<Id>();
            for (Order o : lastOrderByAcct.values()) lastOrderIds.add(o.Id);
            if (!lastOrderIds.isEmpty()) {
                for (OrderItem oi : [SELECT OrderId, Quantity, Product2.Name FROM OrderItem WHERE OrderId IN :lastOrderIds]) {
                    if (!itemsByOrder.containsKey(oi.OrderId)) itemsByOrder.put(oi.OrderId, new List<String>());
                    String nm = (oi.Product2 != null && oi.Product2.Name != null) ? oi.Product2.Name : 'item';
                    Integer q = (oi.Quantity == null) ? 1 : oi.Quantity.intValue();
                    itemsByOrder.get(oi.OrderId).add(nm + ' x' + q);
                }
            }

            // --- Open cases per account ---
            Map<Id,List<String>> casesByAcct = new Map<Id,List<String>>();
            for (Case c : [SELECT AccountId, CaseNumber, Subject, Status FROM Case
                           WHERE AccountId IN :accountIds AND IsClosed = false ORDER BY CreatedDate DESC]) {
                if (c.AccountId == null) continue;
                if (!casesByAcct.containsKey(c.AccountId)) casesByAcct.put(c.AccountId, new List<String>());
                casesByAcct.get(c.AccountId).add('#' + c.CaseNumber + ' ' + c.Status + (String.isNotBlank(c.Subject) ? ' (' + c.Subject + ')' : ''));
            }

            // --- Upcoming service visits per account ---
            Map<Id,List<String>> visitsByAcct = new Map<Id,List<String>>();
            for (ServiceAppointment sa : [SELECT AccountId, Subject, Status, SchedStartTime FROM ServiceAppointment
                                          WHERE AccountId IN :accountIds AND Status NOT IN ('Completed','Canceled','Cannot Complete')
                                          ORDER BY SchedStartTime ASC NULLS LAST]) {
                if (sa.AccountId == null) continue;
                if (!visitsByAcct.containsKey(sa.AccountId)) visitsByAcct.put(sa.AccountId, new List<String>());
                String whenStr = (sa.SchedStartTime != null) ? sa.SchedStartTime.date().format() : 'TBD';
                visitsByAcct.get(sa.AccountId).add((String.isNotBlank(sa.Subject) ? sa.Subject : 'visit') + ' ' + sa.Status + ' ' + whenStr);
            }

            // --- Active subscriptions per account ---
            Map<Id,List<String>> subsByAcct = new Map<Id,List<String>>();
            for (Asset a : [SELECT AccountId, Name, Quantity, Status, UsageEndDate FROM Asset
                            WHERE AccountId IN :accountIds AND Status != 'Obsolete' ORDER BY InstallDate DESC]) {
                if (a.AccountId == null) continue;
                if (!subsByAcct.containsKey(a.AccountId)) subsByAcct.put(a.AccountId, new List<String>());
                Integer q = (a.Quantity == null) ? 1 : a.Quantity.intValue();
                String ren = (a.UsageEndDate != null) ? ', renews ' + a.UsageEndDate.format() : '';
                subsByAcct.get(a.AccountId).add(a.Name + ' x' + q + ' (' + a.Status + ren + ')');
            }

            // --- Assemble per account ---
            for (Id aid : accountIds) {
                List<String> lines = new List<String>();
                String prof = profileLine(accById.get(aid));
                if (prof != null) lines.add(prof);

                Order lo = lastOrderByAcct.get(aid);
                if (lo != null) {
                    String items = '';
                    if (itemsByOrder.containsKey(lo.Id)) items = ' — ' + String.join(itemsByOrder.get(lo.Id), ', ');
                    String tot = (lo.Woo_Order_Total__c != null) ? ' $' + String.valueOf(lo.Woo_Order_Total__c) : '';
                    String trk = String.isNotBlank(lo.Tracking_Number__c) ? ' track ' + lo.Tracking_Number__c : '';
                    lines.add('LAST ORDER #' + lo.OrderNumber + ' ' + lo.Status + tot + trk + items);
                }
                if (casesByAcct.containsKey(aid))  lines.add('OPEN CASES: ' + String.join(casesByAcct.get(aid), '; '));
                if (visitsByAcct.containsKey(aid)) lines.add('SERVICE VISITS: ' + String.join(visitsByAcct.get(aid), '; '));
                if (subsByAcct.containsKey(aid))   lines.add('SUBSCRIPTIONS: ' + String.join(subsByAcct.get(aid), '; '));

                if (!lines.isEmpty()) out.put(aid, 'VERIFIED CUSTOMER BRIEF (pre-stamped, read-only context):\n' + String.join(lines, '\n'));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CustomerBriefBuilder skipped: ' + e.getMessage());
        }
        return out;
    }

    private static String profileLine(Account a) {
        if (a == null) return null;
        List<String> p = new List<String>();
        if (String.isNotBlank(a.Data_Cloud_Segment__c)) p.add('segment ' + a.Data_Cloud_Segment__c);
        if (a.Insights_LTV__c != null)                   p.add('LTV ~$' + String.valueOf(a.Insights_LTV__c.setScale(0)));
        else if (a.Predicted_LTV__c != null)             p.add('predicted LTV ~$' + String.valueOf(a.Predicted_LTV__c.setScale(0)));
        if (String.isNotBlank(a.Brands_Purchased__c))    p.add('brands: ' + a.Brands_Purchased__c);
        if (a.Is_Multi_Brand__c == true)                 p.add('MULTI-BRAND (ok to acknowledge cross-store)');
        if (String.isNotBlank(a.Churn_Risk_Tier__c))     p.add('churn tier ' + a.Churn_Risk_Tier__c);
        return p.isEmpty() ? null : 'PROFILE: ' + String.join(p, '; ') + '.';
    }
}
