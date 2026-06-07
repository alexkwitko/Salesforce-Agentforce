/**
 * ProductSuggestionService — read-only grounding for the agent's "extra" suggestions.
 * Returns real in-stock catalog SKUs (best-sellers) excluding given ids, so the agent can propose
 * additional items WITHOUT hallucinating products. No side effects.
 */
public without sharing class ProductSuggestionService {

    public class Request {
        @InvocableVariable(label='Exclude Product Ids CSV') public String excludeIdsCsv;
        @InvocableVariable(label='How Many') public Integer howMany;
    }
    public class Result {
        @InvocableVariable public String productIdsCsv;
        @InvocableVariable public String productNames;   // human-readable list
        @InvocableVariable public Integer count;
    }

    @InvocableMethod(label='Suggest Products (grounded)'
        description='Returns real in-stock products (best-sellers) excluding given ids, for AI extra suggestions. Read-only.')
    public static List<Result> suggest(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r));
        return out;
    }

    private static Result build(Request r) {
        Result res = new Result();
        Integer lim = (r.howMany == null || r.howMany <= 0) ? 3 : r.howMany;
        Set<Id> exclude = new Set<Id>();
        if (String.isNotBlank(r.excludeIdsCsv)) {
            for (String s : r.excludeIdsCsv.split(',')) { String t = s.trim(); if (String.isNotBlank(t)) { try { exclude.add((Id) t); } catch (Exception e) {} } }
        }
        if (exclude.isEmpty()) exclude.add(null);
        // best-sellers overall, in stock, active
        List<AggregateResult> ars = [
            SELECT Product2Id pid, SUM(Quantity) q FROM OrderItem
            WHERE Product2.IsActive = true AND Product2.Stock_On_Hand__c > 0
              AND Product2.Woo_Product_Id__c != null AND Product2Id NOT IN :exclude
            GROUP BY Product2Id ORDER BY SUM(Quantity) DESC LIMIT :lim];
        List<Id> ids = new List<Id>();
        for (AggregateResult ar : ars) ids.add((Id) ar.get('pid'));
        List<String> names = new List<String>(); List<String> idStr = new List<String>();
        if (!ids.isEmpty()) {
            for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id IN :ids]) { names.add(p.Name); idStr.add(p.Id); }
        }
        res.productIdsCsv = String.join(idStr, ',');
        res.productNames = String.join(names, ', ');
        res.count = idStr.size();
        return res;
    }
}
