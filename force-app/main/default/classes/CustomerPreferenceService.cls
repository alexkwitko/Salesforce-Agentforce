/**
 * CustomerPreferenceService — persist customer coffee preferences to the Person Account
 * (Account.Coffee_Preferences__c) AND the Customer_Journey__c, as merged JSON. This is the
 * durable record the Concierge MUST check before recommending, and it flows to the Data Cloud
 * unified profile via the Account → Individual ingestion.
 *
 * Preferences shape: { "likes":[], "dislikes":[], "roast":"", "format":"", "brew":"", "notes":"" }
 * Calls are additive/merge — passing a single dislike appends it without wiping the rest.
 */
public without sharing class CustomerPreferenceService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Like (append)') public String likeItem;
        @InvocableVariable(label='Dislike (append)') public String dislikeItem;
        @InvocableVariable(label='Roast Level (light/medium/dark)') public String roast;
        @InvocableVariable(label='Format (whole bean/ground)') public String format;
        @InvocableVariable(label='Brew Method (espresso/pour-over/cold brew/...)') public String brew;
        // --- independent preference axes (orthogonal to each other) ---
        @InvocableVariable(label='Bean Type (single-origin/blend)') public String beanType;
        @InvocableVariable(label='Caffeine (regular/decaf)') public String caffeine;
        @InvocableVariable(label='Flavored Preference (avoid/ok)') public String flavored;
        @InvocableVariable(label='Free-text Notes (append)') public String notes;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String preferencesJson;
        @InvocableVariable public String summary;
    }

    @InvocableMethod(label='Save Customer Preferences'
        description='Merges likes/dislikes/roast/format/brew/notes into the Person Account and journey. Call this whenever the customer states a preference (e.g., "I do not like decaf"). Returns the full merged preferences.')
    public static List<Result> save(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doSave(r));
        return out;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Result doSave(Request r) {
        Result res = new Result(); res.success = false;
        if (String.isBlank(r.email)) { res.summary = 'No email.'; return res; }

        // load existing prefs from Account (preferred) or Journey
        Account acc = null;
        for (Account a : [SELECT Id, Coffee_Preferences__c FROM Account WHERE PersonEmail = :r.email LIMIT 1]) acc = a;
        Customer_Journey__c j = null;
        for (Customer_Journey__c cj : [SELECT Id, Preferences__c FROM Customer_Journey__c WHERE Email__c = :r.email LIMIT 1]) j = cj;

        Map<String, Object> prefs = parse(acc != null ? acc.Coffee_Preferences__c
                                          : (j != null ? j.Preferences__c : null));

        List<Object> likes = asList(prefs.get('likes'));
        List<Object> dislikes = asList(prefs.get('dislikes'));
        if (String.isNotBlank(r.likeItem) && !containsCI(likes, r.likeItem)) likes.add(r.likeItem.trim());
        if (String.isNotBlank(r.dislikeItem)) {
            if (!containsCI(dislikes, r.dislikeItem)) dislikes.add(r.dislikeItem.trim());
            // a new dislike removes any matching like
            likes = removeCI(likes, r.dislikeItem);
        }
        prefs.put('likes', likes);
        prefs.put('dislikes', dislikes);
        if (String.isNotBlank(r.roast))    prefs.put('roast', r.roast.trim());
        if (String.isNotBlank(r.format))   prefs.put('format', r.format.trim());
        if (String.isNotBlank(r.brew))     prefs.put('brew', r.brew.trim());
        if (String.isNotBlank(r.beanType)) prefs.put('beanType', normBeanType(r.beanType));
        if (String.isNotBlank(r.caffeine)) {
            String ct = r.caffeine.trim().toLowerCase();
            // "no decaf" / "regular" / "caffeinated" -> regular; bare "decaf" / "want decaf" -> decaf
            String c = (ct.contains('regular') || ct.contains('caffeinat') || ct.startsWith('no')
                        || ct.contains('not decaf') || ct.contains('no decaf')) ? 'regular'
                       : (ct.contains('decaf') ? 'decaf' : 'regular');
            prefs.put('caffeine', c);
            // keep dislikes in sync for backward-compat with the keyword filter
            if (c == 'regular' && !containsCI(dislikes, 'decaf')) { dislikes.add('decaf'); prefs.put('dislikes', dislikes); }
            if (c == 'decaf') { dislikes = removeCI(dislikes, 'decaf'); prefs.put('dislikes', dislikes); }
        }
        if (String.isNotBlank(r.flavored)) {
            String f = r.flavored.trim().toLowerCase().startsWith('avoid') ? 'avoid' : 'ok';
            prefs.put('flavored', f);
            if (f == 'avoid' && !containsCI(dislikes, 'flavored')) { dislikes.add('flavored'); prefs.put('dislikes', dislikes); }
        }
        if (String.isNotBlank(r.notes)) {
            String existing = (String) prefs.get('notes');
            prefs.put('notes', String.isBlank(existing) ? r.notes.trim() : (existing + ' | ' + r.notes.trim()));
        }

        String serialized = JSON.serialize(prefs);
        if (serialized.length() > 3900) serialized = serialized.substring(0, 3900);

        if (acc != null) { acc.Coffee_Preferences__c = serialized; update acc; }
        // Ensure a journey exists so preferences ALWAYS persist — even for a brand-new shopper who
        // has no Person Account and no journey yet (previously this saved to nothing).
        if (j == null) j = JourneyService.getOrCreate(r.email, (acc != null ? acc.Id : null), null);
        if (j != null)   { j.Preferences__c = serialized.length() > 255 ? serialized.substring(0,255) : serialized; update j; }

        res.success = true;
        res.preferencesJson = serialized;
        res.summary = 'Saved. likes=' + likes + ' dislikes=' + dislikes
            + (prefs.get('beanType') == null ? '' : ' beanType=' + prefs.get('beanType'))
            + (prefs.get('brew') == null ? '' : ' brew=' + prefs.get('brew'))
            + (prefs.get('roast') == null ? '' : ' roast=' + prefs.get('roast'))
            + (prefs.get('caffeine') == null ? '' : ' caffeine=' + prefs.get('caffeine'))
            + (prefs.get('flavored') == null ? '' : ' flavored=' + prefs.get('flavored'));
        return res;
    }

    private static String normBeanType(String s) {
        String t = s.trim().toLowerCase();
        if (t.startsWith('single') || t.contains('origin')) return 'single-origin';
        if (t.contains('blend')) return 'blend';
        return s.trim();
    }

    private static Map<String, Object> parse(String rawJson) {
        if (String.isBlank(rawJson)) return new Map<String, Object>();
        try { return (Map<String, Object>) JSON.deserializeUntyped(rawJson); }
        catch (Exception e) { return new Map<String, Object>(); }
    }
    private static List<Object> asList(Object o) { return o == null ? new List<Object>() : (List<Object>) o; }
    private static Boolean containsCI(List<Object> l, String v) {
        for (Object o : l) if (String.valueOf(o).equalsIgnoreCase(v.trim())) return true;
        return false;
    }
    private static List<Object> removeCI(List<Object> l, String v) {
        List<Object> out = new List<Object>();
        for (Object o : l) if (!String.valueOf(o).equalsIgnoreCase(v.trim())) out.add(o);
        return out;
    }
}
