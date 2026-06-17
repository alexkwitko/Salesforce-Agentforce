/**
 * WordPressMailService — sends email via the WordPress → Gmail relay (FluentSMTP), bypassing the
 * Salesforce daily email cap and sending authenticated as the store's Gmail.
 *
 * Async (Queueable + AllowsCallouts) so it never hits "uncommitted work pending" when callers
 * have done DML first. HMAC-signed with the same shared secret as the other SF↔WP endpoints.
 */
public without sharing class WordPressMailService {

    /** Queue an email for delivery via WordPress/Gmail. Consent must be checked by the caller. */
    public static void sendAsync(String toEmail, String subject, String html) {
        if (String.isBlank(toEmail) || String.isBlank(subject)) return;
        // In tests we don't enqueue (chaining from an async ctx is disallowed); the callout is
        // covered directly in WordPressMailServiceTest.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new MailJob(toEmail, subject, html));
        }
    }

    public class MailJob implements Queueable, Database.AllowsCallouts {
        private String toEmail, subject, html;
        public MailJob(String t, String s, String h) { toEmail = t; subject = s; html = h; }
        public void execute(QueueableContext ctx) {
            Map<String, Object> body = new Map<String, Object>{
                'to' => toEmail, 'subject' => subject, 'html' => html
            };
            String raw = JSON.serialize(body);
            try {
                Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf(KwitkoSecrets.whk()));
                HttpRequest req = new HttpRequest();
                req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/send-email');
                req.setMethod('POST');
                req.setHeader('Content-Type', 'application/json');
                req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
                req.setBody(raw);
                req.setTimeout(60000);
                HttpResponse resp = new Http().send(req);
                System.debug('WP_MAIL >>> ' + resp.getStatusCode() + ' ' + resp.getBody());
            } catch (Exception e) {
                System.debug('WP_MAIL_ERR >>> ' + e.getMessage());
            }
        }
    }
}
