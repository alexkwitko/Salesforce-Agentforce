/**
 * Pushes a Product2 to WooCommerce (SF is the catalog system of record).
 * Invocable (called from the "Sync Product to WooCommerce" Flow) enqueues a Queueable
 * so the HTTP callout runs outside the trigger transaction. The Queueable does the
 * create/update via the WooCommerce Named Credential and stamps the sync-tracking fields.
 */
public without sharing class WooProductSync implements Queueable, Database.AllowsCallouts {

    private Id productId;
    public WooProductSync(Id productId) { this.productId = productId; }

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
                SELECT Id, Name, Description, IsActive, StockKeepingUnit, Woo_Product_Id__c
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

            HttpRequest req = new HttpRequest();
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
