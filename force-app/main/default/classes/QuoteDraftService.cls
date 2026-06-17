/**
 * QuoteDraftService — helpers for the AI Quote-Drafting Copilot.
 * Builds STANDARD Salesforce Quotes (Quote + QuoteLineItem) from natural language —
 * gives an "Agentforce quoting" experience without the gated RLM Place Quote engine.
 */
public with sharing class QuoteDraftService {

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
        @InvocableVariable(label='Quote Id') public String quoteId;
    }

    public static Id resolveAccount(String accountName, String email) {
        if (String.isNotBlank(email)) {
            List<Contact> c = [SELECT AccountId FROM Contact WHERE Email = :email AND AccountId != null LIMIT 1];
            if (!c.isEmpty()) return c[0].AccountId;
        }
        if (String.isNotBlank(accountName)) {
            List<Account> a = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
            if (!a.isEmpty()) return a[0].Id;
            String p = '%' + accountName + '%';
            List<Account> f = [SELECT Id FROM Account WHERE Name LIKE :p LIMIT 1];
            if (!f.isEmpty()) return f[0].Id;
        }
        return null;
    }

    public static Id standardPricebookId() {
        return [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
    }

    // Quote requires an Opportunity — reuse an open one or create a lightweight one.
    public static Opportunity findOrCreateOpp(Id acctId) {
        List<Opportunity> o = [SELECT Id FROM Opportunity WHERE AccountId = :acctId AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 1];
        if (!o.isEmpty()) return o[0];
        Opportunity opp = new Opportunity(Name = 'New Business', AccountId = acctId,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert opp;
        return opp;
    }

    // Match a product by exact code OR fuzzy name, on the standard price book.
    public static PricebookEntry findEntry(String product, Id stdPb) {
        String pattern = '%' + product + '%';
        List<PricebookEntry> pbes = [
            SELECT Id, Product2Id, Product2.Name, UnitPrice
            FROM PricebookEntry
            WHERE (Product2.ProductCode = :product OR Product2.Name LIKE :pattern)
                  AND IsActive = true AND Pricebook2Id = :stdPb
            ORDER BY Product2.ProductCode NULLS LAST LIMIT 1
        ];
        return pbes.isEmpty() ? null : pbes[0];
    }
}
