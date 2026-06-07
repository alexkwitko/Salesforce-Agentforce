/**
 * WooOrderPull — reliable, scheduled PULL of recent WooCommerce orders into Salesforce.
 * Removes dependence on WooCommerce webhooks/WP-Cron (which deliver late on quiet stores).
 * Runs as a privileged user; ingestion is idempotent (WooOrderService skips existing orders).
 */
public without sharing class WooOrderPull implements Schedulable {
    public void execute(SchedulableContext sc) { System.enqueueJob(new PullJob()); }

    public class PullJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) { pull(); }
    }

    public static Integer pull() {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:WooCommerce/wp-json/wc/v3/orders?per_page=20&orderby=date&order=desc');
        req.setMethod('GET');
        req.setTimeout(120000);
        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() != 200) { System.debug('Pull failed: ' + resp.getStatusCode()); return 0; }
        List<Object> orders = (List<Object>) JSON.deserializeUntyped(resp.getBody());
        Integer n = 0;
        for (Object o : orders) {
            try { if (WooOrderService.ingestOrder((Map<String,Object>) o) != null) n++; }
            catch (Exception e) { System.debug('pull ingest err: ' + e.getMessage()); }
        }
        return n;
    }
}
