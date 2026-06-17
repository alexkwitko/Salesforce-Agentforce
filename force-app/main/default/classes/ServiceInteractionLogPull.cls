/**
 * Pulls storefront-captured service chat turns from Woo and writes closed audit Cases.
 *
 * Why this exists: Agentforce can answer some follow-up service turns from conversation context
 * without invoking a case-writing action. The browser listener captures those user turns, and this
 * signed pull closes the audit gap without trusting the model to choose an action every time.
 */
public without sharing class ServiceInteractionLogPull
        implements Schedulable {
    private static final Integer DEFAULT_LIMIT = 50;

    public class Entry {
        public String id;
        public String category;
        public String message;
        public String email;
        public String conversationId;
        public String token;
        public String page;
        public String createdAt;
        public Boolean loggedIn;
    }

    public class PullResponse {
        public List<Entry> records;
        public String bridge_version;
    }

    public class Result {
        public Integer pulled = 0;
        public Integer created = 0;
        public String error;
    }

    public void execute(SchedulableContext sc) {
        System.enqueueJob(new PullJob());
    }

    public static Result runNow() {
        Result result = new Result();
        List<Entry> entries = pull(DEFAULT_LIMIT, result);
        result.pulled = entries.size();
        if (entries.isEmpty()) return result;

        Set<String> ids = new Set<String>();
        for (Entry entry : entries) {
            if (entry != null && String.isNotBlank(entry.id)) ids.add(entry.id.trim());
        }
        if (ids.isEmpty()) return result;

        Set<String> existingIds = new Set<String>();
        for (Case existing : [
            SELECT Service_Interaction_Id__c
            FROM Case
            WHERE Service_Interaction_Id__c IN :ids
        ]) {
            existingIds.add(existing.Service_Interaction_Id__c);
        }

        Map<String, Account> accountsByEmail = accountsByEmail(entries);
        Map<Id, Order> latestOrderByAccount = latestOrderByAccount(accountsByEmail.values());
        List<Case> cases = new List<Case>();
        List<Entry> caseEntries = new List<Entry>();
        List<String> ackIds = new List<String>();

        for (Entry entry : entries) {
            if (entry == null || String.isBlank(entry.id)) continue;
            if (existingIds.contains(entry.id)) {
                ackIds.add(entry.id);
                continue;
            }
            String category = normalizeCategory(entry.category, entry.message);
            if (String.isBlank(category)) continue;

            String email = cleanEmail(entry.email);
            Account acc = String.isBlank(email) ? null : accountsByEmail.get(email.toLowerCase());
            Order orderRecord = acc == null ? null : latestOrderByAccount.get(acc.Id);
            String message = sanitizeMessage(entry.message);
            String resolution = 'Service chat turn logged from the storefront: "' + message + '". '
                + 'The agent may have resolved this turn from existing context; this closed case preserves the customer interaction.';
            String transcript = 'Source: storefront onEmbeddedMessageSent'
                + '\nInteraction Id: ' + entry.id
                + (String.isBlank(entry.conversationId) ? '' : '\nConversation Id: ' + entry.conversationId)
                + (String.isBlank(entry.page) ? '' : '\nPage: ' + entry.page)
                + (String.isBlank(entry.createdAt) ? '' : '\nStorefront Time: ' + entry.createdAt)
                + '\nCustomer Message: ' + message;

            cases.add(new Case(
                AccountId = acc == null ? null : acc.Id,
                ContactId = acc == null ? null : acc.PersonContactId,
                SuppliedEmail = String.isBlank(email) ? null : email,
                Order__c = orderRecord == null ? null : orderRecord.Id,
                Woo_Order_Id__c = orderRecord == null ? null : orderRecord.Woo_Order_Id__c,
                Origin = 'Chat',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = category,
                Subject = truncate('Chat service: Web turn logged - ' + category, 255),
                Summary__c = truncate(resolution, 4000),
                Description = CaseTranscriptUtil.append(resolution, transcript),
                Resolution__c = truncate(resolution, 4000),
                Resolved_By__c = 'Storefront service logger',
                Service_Interaction_Id__c = entry.id
            ));
            caseEntries.add(entry);
            ackIds.add(entry.id);
        }

        if (!cases.isEmpty()) {
            insert cases;
            result.created = cases.size();
            for (Integer i = 0; i < cases.size(); i += 1) {
                Case c = cases[i];
                Entry entry = caseEntries[i];
                if (c.Id != null) {
                    CaseTranscriptUtil.insertTaskWithResolution(
                        c.Id,
                        c.ContactId,
                        c.Resolution__c,
                        'Storefront captured service message: ' + sanitizeMessage(entry == null ? null : entry.message)
                    );
                }
            }
        }

        if (!ackIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AckJob(ackIds));
        } else if (!ackIds.isEmpty() && Test.isRunningTest()) {
            System.enqueueJob(new AckJob(ackIds));
        }
        return result;
    }

    private static List<Entry> pull(Integer limitSize, Result result) {
        List<Entry> out = new List<Entry>();
        try {
            Map<String, Object> body = new Map<String, Object>{
                'limit' => limitSize == null ? DEFAULT_LIMIT : limitSize
            };
            HttpResponse resp = signedPost('/wp-json/kwitko/v1/service-interactions/pull', JSON.serialize(body));
            if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
                result.error = 'Woo service-interaction pull failed: ' + resp.getStatusCode() + ' ' + resp.getBody();
                return out;
            }
            PullResponse parsed = (PullResponse) JSON.deserialize(resp.getBody(), PullResponse.class);
            if (parsed != null && parsed.records != null) out.addAll(parsed.records);
        } catch (Exception e) {
            result.error = 'Woo service-interaction pull exception: ' + e.getMessage();
        }
        return out;
    }

    private static HttpResponse signedPost(String path, String rawBody) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(rawBody), Blob.valueOf(KwitkoSecrets.whk()));
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:WooCommerce' + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
        req.setBody(rawBody);
        req.setTimeout(60000);
        return new Http().send(req);
    }

    private static Map<String, Account> accountsByEmail(List<Entry> entries) {
        Set<String> emails = new Set<String>();
        for (Entry entry : entries) {
            String email = cleanEmail(entry == null ? null : entry.email);
            if (String.isNotBlank(email)) emails.add(email.toLowerCase());
        }
        Map<String, Account> out = new Map<String, Account>();
        if (emails.isEmpty()) return out;
        for (Account acc : [
            SELECT Id, PersonContactId, PersonEmail
            FROM Account
            WHERE PersonEmail IN :emails
        ]) {
            if (String.isNotBlank(acc.PersonEmail)) out.put(acc.PersonEmail.toLowerCase(), acc);
        }
        return out;
    }

    private static Map<Id, Order> latestOrderByAccount(List<Account> accounts) {
        Set<Id> accountIds = new Set<Id>();
        for (Account acc : accounts) if (acc != null) accountIds.add(acc.Id);
        Map<Id, Order> out = new Map<Id, Order>();
        if (accountIds.isEmpty()) return out;
        for (Order orderRecord : [
            SELECT Id, AccountId, Woo_Order_Id__c, EffectiveDate, CreatedDate
            FROM Order
            WHERE AccountId IN :accountIds
            ORDER BY EffectiveDate DESC NULLS LAST, CreatedDate DESC
        ]) {
            if (!out.containsKey(orderRecord.AccountId)) out.put(orderRecord.AccountId, orderRecord);
        }
        return out;
    }

    private static String normalizeCategory(String category, String message) {
        String c = String.isBlank(category) ? '' : category.trim();
        Set<String> allowed = new Set<String>{ 'Order', 'Shipping', 'Returns', 'Refund', 'Product', 'Billing', 'Account', 'Escalation' };
        if (allowed.contains(c)) return c;
        String m = String.isBlank(message) ? '' : message.toLowerCase();
        if (m.contains('return') || m.contains('exchange') || m.contains('label')) return 'Returns';
        if (m.contains('refund')) return 'Refund';
        if (m.contains('track') || m.contains('ship') || m.contains('deliver')) return 'Shipping';
        if (m.contains('pay') || m.contains('billing') || m.contains('card')) return 'Billing';
        if (m.contains('login') || m.contains('sign in') || m.contains('account') || m.contains('password')) return 'Account';
        if (m.contains('case') || m.contains('human') || m.contains('agent') || m.contains('complaint')) return 'Escalation';
        if (m.contains('order') || m.contains('cancel')) return 'Order';
        return null;
    }

    private static String cleanEmail(String value) {
        if (String.isBlank(value)) return null;
        String email = value.trim().toLowerCase();
        return email.contains('@') ? email : null;
    }

    private static String sanitizeMessage(String value) {
        String message = String.isBlank(value) ? 'Service follow-up message was empty.' : value.trim();
        message = message.replaceAll('(?i)\\b(otp|verification code|one-time(?: email)? code|code)\\s*[:#=]?\\s*\\(?\\d{6}\\)?', '$1 [redacted]');
        message = message.replaceAll('\\b\\d{6}\\b', '[redacted]');
        return truncate(message, 1000);
    }

    private static String truncate(String value, Integer maxLen) {
        if (value == null || maxLen == null || maxLen <= 0) return value;
        return value.length() > maxLen ? value.substring(0, maxLen) : value;
    }

    public class AckJob implements Queueable, Database.AllowsCallouts {
        private List<String> ids;
        public AckJob(List<String> ids) {
            this.ids = new List<String>();
            if (ids != null) this.ids.addAll(ids);
        }
        public void execute(QueueableContext qc) {
            if (ids.isEmpty()) return;
            Map<String, Object> body = new Map<String, Object>{ 'ids' => ids };
            try {
                signedPost('/wp-json/kwitko/v1/service-interactions/ack', JSON.serialize(body));
            } catch (Exception e) {
                System.debug('Woo service-interaction ack failed: ' + e.getMessage());
            }
        }
    }

    public class PullJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext qc) {
            runNow();
        }
    }
}
