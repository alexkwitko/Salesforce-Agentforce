/**
 * Deterministic per-product spec lookup for the Concierge.
 * build_strategy only returns specs for its 1-2 picks; when a shopper asks about
 * an arbitrary named product ("tell me about the first one"), the agent calls this
 * to fetch the authored Product_Specs__c verbatim — brand-scoped, exact-name match —
 * so it relays real specs instead of inventing them.
 */
public without sharing class ProductSpecsService {

    public class Request {
        @InvocableVariable(label='Product Names (CSV)' description='Exact product name(s), comma-separated, to fetch specs for' required=true)
        public String productNamesCsv;
        @InvocableVariable(label='Brand' description='Kwitko Coffee or Bean & Brew — scopes the lookup to the current store' required=true)
        public String brand;
    }

    public class Result {
        @InvocableVariable public String specs;   // one line per product: "Name: specs"
        @InvocableVariable public Boolean found;   // true if at least one product had specs
    }

    @InvocableMethod(label='Get Product Specs' description='Returns authored, deterministic specs for the named products (brand-scoped, exact name). Call this before describing any specific product so specs are never invented.')
    public static List<Result> getSpecs(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            Result res = new Result();
            res.found = false;

            String b = (r.brand != null && r.brand.startsWithIgnoreCase('Bean')) ? 'Bean & Brew' : 'Kwitko Coffee';

            Set<String> names = new Set<String>();
            if (String.isNotBlank(r.productNamesCsv)) {
                for (String n : r.productNamesCsv.split(',')) {
                    if (String.isNotBlank(n)) names.add(n.trim());
                }
            }

            List<String> lines = new List<String>();
            if (!names.isEmpty()) {
                for (Product2 p : [
                    SELECT Name, Product_Specs__c
                    FROM Product2
                    WHERE Name IN :names AND Brand__c = :b AND IsActive = true
                ]) {
                    if (String.isNotBlank(p.Product_Specs__c)) {
                        lines.add(p.Name + ': ' + p.Product_Specs__c);
                        res.found = true;
                    } else {
                        lines.add(p.Name + ': (no detailed specs on file)');
                    }
                }
            }

            res.specs = lines.isEmpty()
                ? 'No matching product found in this store.'
                : String.join(lines, '\n');
            out.add(res);
        }
        return out;
    }
}
