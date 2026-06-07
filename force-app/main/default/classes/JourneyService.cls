/**
 * JourneyService
 * The orchestrator's MEMORY. Persists one Customer_Journey__c per customer (keyed by email)
 * plus an append-only Agent_Interaction__c log, so the orchestrator can:
 *   - know what was already recommended / purchased (never repeat),
 *   - know which orders already got a post-purchase offer (never double-fire),
 *   - pass purchased ids to the post-purchase agent as the exclude set.
 *
 * Invocable so the agents/orchestrator call it directly; static methods for Apex callers
 * (e.g. WooOrderService records purchases at ingestion time).
 *
 * `without sharing`: trusted back-end memory written by automation running as various users.
 */
public without sharing class JourneyService {

    // ---------- get_journey_state ----------
    public class StateRequest {
        @InvocableVariable(label='Email' description='Customer email (journey key).' required=true)
        public String email;
    }
    public class State {
        @InvocableVariable(label='Is Returning') public Boolean isReturning;
        @InvocableVariable(label='Recommended Product Ids') public String recommendedProductIds;
        @InvocableVariable(label='Purchased Product Ids') public String purchasedProductIds;
        @InvocableVariable(label='Post-Purchase Done Order Ids') public String postPurchaseDoneOrderIds;
        @InvocableVariable(label='Last Stage') public String lastStage;
        @InvocableVariable(label='Last Agent') public String lastAgent;
        @InvocableVariable(label='Journey Id') public String journeyId;
        @InvocableVariable(label='Found') public Boolean found;
    }

    @InvocableMethod(label='Get Journey State'
        description='Returns the customer journey memory by email. The orchestrator MUST call this first on every invocation to avoid duplicate work and repeated recommendations.')
    public static List<State> getJourneyState(List<StateRequest> reqs) {
        List<State> out = new List<State>();
        for (StateRequest r : reqs) out.add(buildState(r.email));
        return out;
    }

    private static State buildState(String email) {
        State s = new State();
        s.found = false; s.isReturning = false;
        if (String.isBlank(email)) return s;
        List<Customer_Journey__c> js = [
            SELECT Id, Recommended_Product_Ids__c, Purchased_Product_Ids__c,
                   Post_Purchase_Done_Order_Ids__c, Last_Stage__c, Last_Agent__c
            FROM Customer_Journey__c WHERE Email__c = :email LIMIT 1];
        if (js.isEmpty()) return s;
        Customer_Journey__c j = js[0];
        s.found = true;
        s.journeyId = j.Id;
        s.recommendedProductIds = j.Recommended_Product_Ids__c;
        s.purchasedProductIds = j.Purchased_Product_Ids__c;
        s.postPurchaseDoneOrderIds = j.Post_Purchase_Done_Order_Ids__c;
        s.lastStage = j.Last_Stage__c;
        s.lastAgent = j.Last_Agent__c;
        s.isReturning = String.isNotBlank(j.Purchased_Product_Ids__c);
        return s;
    }

    // ---------- log_interaction (public API; invocable wrapper lives in JourneyLogger) ----------
    /** Append an interaction + update journey memory. Returns a status string. */
    public static String recordInteraction(String email, String agent, String action, String productIds,
            String orderId, String result, String stage, String addRecommendedProductIds,
            String markPostPurchaseDoneOrderId) {
        Customer_Journey__c j = getOrCreate(email, null, null);
        if (j == null) return 'No email; nothing logged.';
        if (String.isNotBlank(addRecommendedProductIds)) {
            j.Recommended_Product_Ids__c = addIds(j.Recommended_Product_Ids__c, csvToSet(addRecommendedProductIds));
        }
        if (String.isNotBlank(markPostPurchaseDoneOrderId)) {
            j.Post_Purchase_Done_Order_Ids__c = addIds(j.Post_Purchase_Done_Order_Ids__c,
                new Set<String>{ markPostPurchaseDoneOrderId });
        }
        if (String.isNotBlank(stage)) j.Last_Stage__c = stage;
        if (String.isNotBlank(agent)) j.Last_Agent__c = agent;
        j.Last_Interaction__c = System.now();
        update j;

        Id ordId = null;
        if (String.isNotBlank(orderId)) { try { ordId = (Id) orderId; } catch (Exception e) {} }
        insert new Agent_Interaction__c(
            Customer_Journey__c = j.Id, Agent__c = agent, Action__c = action,
            Product_Ids__c = productIds, Order__c = ordId, Result__c = result);
        return 'Logged interaction on journey ' + j.Id;
    }

    // ---------- static helpers (Apex callers) ----------

    /** Upsert one journey per email; links Account/Lead when provided.
     *  Email__c is UNIQUE, so a naive SELECT-then-INSERT throws DUPLICATE_VALUE when the SELECT misses
     *  (email case/whitespace mismatch, or two actions in the same turn). That exception used to break
     *  the calling agent action (e.g. issue_coupon → broken add-to-cart). We normalize the email and
     *  tolerate the duplicate by re-fetching, so this can NEVER throw on an existing email. */
    public static Customer_Journey__c getOrCreate(String email, Id accountId, Id leadId) {
        if (String.isBlank(email)) return null;
        String e = email.trim();
        Customer_Journey__c j = lookup(e, email);
        if (j != null) {
            Boolean dirty = false;
            if (accountId != null && j.Account__c != accountId) { j.Account__c = accountId; dirty = true; }
            if (leadId != null && j.Lead__c != leadId) { j.Lead__c = leadId; dirty = true; }
            if (dirty) update j;
            return j;
        }
        // none found — create, but tolerate the unique-Email__c constraint (race / normalization mismatch)
        j = new Customer_Journey__c(Name = e.left(80), Email__c = e);
        if (accountId != null) j.Account__c = accountId;
        if (leadId != null) j.Lead__c = leadId;
        try {
            insert j;
        } catch (DmlException de) {
            Customer_Journey__c again = lookup(e, email);
            if (again == null) throw de;        // genuinely not a duplicate-email problem
            if (accountId != null) again.Account__c = accountId;
            if (leadId != null) again.Lead__c = leadId;
            if (accountId != null || leadId != null) update again;
            j = again;
        }
        return j;
    }

    /** Find an existing journey by email, tolerant of case/whitespace variants — Email__c is a
     *  case-insensitively-UNIQUE field but SOQL '=' is case-sensitive, so we also try the lowercased form. */
    private static Customer_Journey__c lookup(String trimmedEmail, String originalEmail) {
        Customer_Journey__c j = findByEmail(trimmedEmail);
        if (j == null) j = findByEmail(trimmedEmail.toLowerCase());
        if (j == null && originalEmail != trimmedEmail) j = findByEmail(originalEmail);
        return j;
    }

    private static Customer_Journey__c findByEmail(String email) {
        List<Customer_Journey__c> rows = [
            SELECT Id, Email__c, Account__c, Lead__c, Recommended_Product_Ids__c,
                   Purchased_Product_Ids__c, Post_Purchase_Done_Order_Ids__c, Last_Stage__c, Last_Agent__c
            FROM Customer_Journey__c WHERE Email__c = :email LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Record a purchase: append product ids, set stage, log it. Called at order ingestion. */
    public static void recordPurchase(String email, Id accountId, List<Id> productIds, Id orderId) {
        Customer_Journey__c j = getOrCreate(email, accountId, null);
        if (j == null) return;
        Set<String> pset = new Set<String>();
        if (productIds != null) for (Id p : productIds) if (p != null) pset.add(String.valueOf(p));
        j.Purchased_Product_Ids__c = addIds(j.Purchased_Product_Ids__c, pset);
        j.Last_Stage__c = 'Purchased';
        j.Last_Agent__c = 'system';
        j.Last_Interaction__c = System.now();
        update j;
        insert new Agent_Interaction__c(
            Customer_Journey__c = j.Id, Agent__c = 'system', Action__c = 'purchase',
            Product_Ids__c = String.join(new List<String>(pset), ','), Order__c = orderId,
            Result__c = 'Order ingested');
    }

    /** Append recommended product ids to the journey (conversion tracking). Lean: no interaction log. */
    public static void addRecommended(String email, String productIdsCsv) {
        if (String.isBlank(email) || String.isBlank(productIdsCsv)) return;
        Customer_Journey__c j = getOrCreate(email, null, null);
        if (j == null) return;
        String merged = addIds(j.Recommended_Product_Ids__c, csvToSet(productIdsCsv));
        if (merged != j.Recommended_Product_Ids__c) {
            j.Recommended_Product_Ids__c = merged;
            j.Last_Interaction__c = System.now();
            update j;
        }
    }

    private static Set<String> csvToSet(String csv) {
        Set<String> out = new Set<String>();
        if (String.isBlank(csv)) return out;
        for (String s : csv.split(',')) if (String.isNotBlank(s.trim())) out.add(s.trim());
        return out;
    }

    private static String addIds(String existing, Set<String> toAdd) {
        Set<String> all = csvToSet(existing);
        all.addAll(toAdd);
        all.remove('');
        return String.join(new List<String>(all), ',');
    }
}
