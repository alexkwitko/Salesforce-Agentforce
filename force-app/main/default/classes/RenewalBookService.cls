/**
 * RenewalBookService — shared helpers for the Renewal & Retention agent.
 * Works the subscription install base (Asset) + Data Cloud churn tier on Account.
 */
public with sharing class RenewalBookService {

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }

    public static Account resolveAccountByName(String name) {
        if (String.isBlank(name)) return null;
        List<Account> exact = [SELECT Id, Name, Churn_Risk_Tier__c, Churn_Score__c FROM Account WHERE Name = :name LIMIT 1];
        if (!exact.isEmpty()) return exact[0];
        String pattern = '%' + name + '%';
        List<Account> fuzzy = [SELECT Id, Name, Churn_Risk_Tier__c, Churn_Score__c FROM Account WHERE Name LIKE :pattern LIMIT 1];
        return fuzzy.isEmpty() ? null : fuzzy[0];
    }

    public static Asset latestActiveSub(Id accountId) {
        List<Asset> a = [
            SELECT Id, Name, Quantity, Price, UsageEndDate, Status
            FROM Asset
            WHERE AccountId = :accountId AND Status = 'Installed' AND Product2.Family = 'Subscription'
            ORDER BY UsageEndDate DESC LIMIT 1
        ];
        return a.isEmpty() ? null : a[0];
    }

    // Churn-tier-driven next-best-action (A = high risk, C = healthy)
    public static String recommend(String tier, Decimal qty) {
        if (tier == 'A') return 'AT-RISK SAVE — high churn risk: lead with a retention offer before renewing';
        if (tier == 'C' && qty != null && qty >= 20) return 'RENEW + UPSELL — healthy, large volume: renew and propose an expansion';
        return 'RENEW — renew on current terms';
    }
}
