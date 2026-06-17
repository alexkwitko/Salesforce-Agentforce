/**
 * Pushes a Product2 to WooCommerce (SF is the catalog system of record).
 * Invocable (called from the "Sync Product to WooCommerce" Flow) enqueues a Queueable
 * so the HTTP callout runs outside the trigger transaction. The Queueable does the
 * create/update via the WooCommerce Named Credential and stamps the sync-tracking fields.
 */
public without sharing class WooProductSync implements Queueable, Database.AllowsCallouts {

    private Id productId;
    public WooProductSync(Id productId) { this.productId = productId; }

    // WooCommerce category ids (children of "Coffee").
    private static final Integer CAT_SINGLE_ORIGIN = 25;
    private static final Integer CAT_BLENDS        = 26;
    // WooCommerce global product-attribute ids (filterable store facets).
    private static final Integer ATTR_ROAST   = 1;  // Roast Level
    private static final Integer ATTR_FLAVOR  = 2;  // Flavor Profile
    private static final Integer ATTR_ORIGIN  = 3;  // Origin
    private static final Integer ATTR_TYPE    = 4;  // Type
    private static final Integer ATTR_BESTFOR = 5;  // Best For (brew style)

    /** Append a visible, filterable global-attribute term when the value is present. */
    private static void addAttr(List<Object> attrs, Integer attrId, String value) {
        if (String.isBlank(value)) return;
        attrs.add(new Map<String, Object>{
            'id'        => attrId,
            'visible'   => true,
            'variation' => false,
            'options'   => new List<String>{ value }
        });
    }

    public class Request {
        @InvocableVariable(required=true)
        public Id productId;
    }

    @InvocableMethod(label='Push Product to WooCommerce' description='Pushes the product to WooCommerce and stamps sync fields')
    public static void enqueue(List<Request> requests) {
        for (Request r : requests) {
            if (r.productId != null) System.enqueueJob(new WooProductSync(r.productId));
        }
    }

    public void execute(QueueableContext ctx) {
        try {
            Product2 p = [
                SELECT Id, Name, Description, IsActive, StockKeepingUnit, Woo_Product_Id__c,
                       Image_URL__c, Stock_On_Hand__c, Bean_Type__c, Roast_Level__c,
                       Brew_Style__c, Origin__c, Flavor_Profile__c
                FROM Product2 WHERE Id = :productId LIMIT 1];

            Decimal price;
            for (PricebookEntry pbe : [
                    SELECT UnitPrice FROM PricebookEntry
                    WHERE Product2Id = :productId AND Pricebook2.IsStandard = true LIMIT 1]) {
                price = pbe.UnitPrice;
            }

            Map<String, Object> body = new Map<String, Object>{
                'name' => p.Name,
                'status' => (p.IsActive ? 'publish' : 'draft')
            };
            if (String.isNotBlank(p.StockKeepingUnit)) body.put('sku', p.StockKeepingUnit);
            if (price != null) body.put('regular_price', String.valueOf(price));
            if (p.Description != null) body.put('description', p.Description);
            // Only send the image on initial create. Re-sending src on every update forces Woo
            // to re-download the file (slow on shared hosting -> "Read timed out").
            Boolean isCreate = String.isBlank(p.Woo_Product_Id__c);
            if (isCreate && String.isNotBlank(p.Image_URL__c)) {
                body.put('images', new List<Object>{
                    new Map<String, Object>{ 'src' => p.Image_URL__c }
                });
            }
            if (p.Stock_On_Hand__c != null) {
                body.put('manage_stock', true);
                body.put('stock_quantity', Integer.valueOf(p.Stock_On_Hand__c));
            }

            // --- Category mapping (Bean_Type__c -> Woo category under "Coffee") ---
            Integer catId = ('Blend' == p.Bean_Type__c) ? CAT_BLENDS
                          : ('Single-Origin' == p.Bean_Type__c) ? CAT_SINGLE_ORIGIN : null;
            if (catId != null) {
                body.put('categories', new List<Object>{
                    new Map<String, Object>{ 'id' => catId }
                });
            }

            // --- Filterable global attributes (facets) ---
            List<Object> attrs = new List<Object>();
            addAttr(attrs, ATTR_TYPE,    p.Bean_Type__c);
            addAttr(attrs, ATTR_ROAST,   p.Roast_Level__c);
            addAttr(attrs, ATTR_FLAVOR,  p.Flavor_Profile__c);
            addAttr(attrs, ATTR_ORIGIN,  p.Origin__c);
            addAttr(attrs, ATTR_BESTFOR, p.Brew_Style__c);
            if (!attrs.isEmpty()) body.put('attributes', attrs);

            HttpRequest req = new HttpRequest();
            req.setTimeout(120000); // shared Woo host can be slow under concurrent load
            String base = 'callout:WooCommerce/wp-json/wc/v3/products';
            if (String.isNotBlank(p.Woo_Product_Id__c)) {
                req.setEndpoint(base + '/' + p.Woo_Product_Id__c);
                req.setMethod('PUT');
            } else {
                req.setEndpoint(base);
                req.setMethod('POST');
            }
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(body));
            HttpResponse resp = new Http().send(req);

            Product2 upd = new Product2(Id = productId);
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300) {
                Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                if (r.get('id') != null) upd.Woo_Product_Id__c = String.valueOf(r.get('id'));
                upd.Woo_Sync_Status__c = 'Synced';
                upd.Woo_Last_Sync_Date__c = System.now();
                upd.Woo_Sync_Error__c = null;
            } else {
                upd.Woo_Sync_Status__c = 'Failed';
                upd.Woo_Sync_Error__c = ('HTTP ' + resp.getStatusCode() + ': ' + resp.getBody()).abbreviate(255);
            }
            update upd;
        } catch (Exception e) {
            if (productId != null) {
                update new Product2(Id = productId,
                    Woo_Sync_Status__c = 'Failed',
                    Woo_Sync_Error__c = e.getMessage().abbreviate(255));
            }
        }
    }
}
