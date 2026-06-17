/**
 * CustomerLookupService — returning-customer recognition (read-only).
 * CRM + Data Cloud implementation: read-only customer recognition, unified-profile match, and
 * verified-only Account augmentation fields for agent grounding.
 */
public without sharing class CustomerLookupService {

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (the signed-in verified email — pass loggedInEmail; required to return sensitive history/context)') public String verifiedEmail;
    }
    public class Result {
        @InvocableVariable public Boolean isReturning;
        @InvocableVariable public String customerStatus;   // Prospect / Customer
        @InvocableVariable public Integer orderCount;
        @InvocableVariable public Decimal lifetimeValue;
        @InvocableVariable public String favoriteCategory;
        @InvocableVariable public String lastOrderDate;
        @InvocableVariable public Boolean unifiedProfileFound;
        @InvocableVariable public String dataCloudIndividualId;
        @InvocableVariable public String dataCloudPreferences;
        @InvocableVariable public String dataCloudSummary;
        @InvocableVariable public String dataCloudSegment;
        @InvocableVariable public String dataCloudChurnRisk;
        @InvocableVariable public String dataCloudNextBestAction;
        @InvocableVariable public Integer dataCloudOrderCount;
        @InvocableVariable public Decimal dataCloudLifetimeValue;
        @InvocableVariable public String dataCloudFavoriteCategory;
        @InvocableVariable public String dataCloudLastAugmentedAt;
        @InvocableVariable public String preferences;   // saved coffee preferences (JSON) — CHECK before recommending
        @InvocableVariable public Boolean emailConsent;  // existing marketing consent on file — do NOT re-ask if true
        // ── cross-agent context (so Concierge / Service / Growth are aware of each other's actions) ──
        @InvocableVariable public Boolean hasSavedCart;       // an Active/Abandoned cart is saved server-side — offer to restore
        @InvocableVariable public String savedCartSummary;    // e.g. "Abandoned cart: 3 items, $89"
        @InvocableVariable public String activeCouponCode;    // unredeemed coupon waiting for them
        @InvocableVariable public String lastAgentAction;     // most recent action by ANY agent (Inside Sales / Service / Growth)
        @InvocableVariable public Integer openCaseCount;      // open support cases (Service context)
        @InvocableVariable public String summary;
    }

    @InvocableMethod(label='Lookup Customer'
        description='Returns returning-customer status + purchase history summary for an email (buyer vs prospect, order count, LTV, favorite category).')
    public static List<Result> lookup(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r.email, r.verifiedEmail));
        return out;
    }

    private static Result build(String email, String verifiedEmail) {
        Result res = new Result();
        res.isReturning = false; res.orderCount = 0; res.lifetimeValue = 0; res.customerStatus = 'Prospect';
        if (String.isBlank(email)) { res.summary = 'No email provided.'; return res; }
        // PII gate: order history, LTV, and cross-agent context (cart/coupon/cases) require a verified
        // sign-in. Taste preferences + returning status are OK unverified (needed for shopping help).
        Boolean verified = IdentityService.isVerified(email, verifiedEmail);

        // D-2: SYNCHRONOUS Data Cloud unified-profile lookup first (CRM enriches/falls back).
        DataCloudProfile dc = dcUnifiedProfile(email);
        res.unifiedProfileFound = dc.found;
        res.dataCloudIndividualId = dc.individualId;
        res.dataCloudPreferences = dc.coffeePreferences;
        res.dataCloudSummary = dc.summary;

        List<Account> accs = [
            SELECT Id, Name, Customer_Status__c, Coffee_Preferences__c, Email_Consent__c,
                   Data_Cloud_Segment__c, Data_Cloud_Churn_Risk__c, Data_Cloud_Next_Best_Action__c,
                   Data_Cloud_Order_Count__c, Data_Cloud_Lifetime_Value__c, Data_Cloud_Favorite_Category__c,
                   Data_Cloud_Last_Augmented_At__c, Data_Cloud_Profile_Summary__c
            FROM Account WHERE PersonEmail = :email LIMIT 1
        ];
        if (accs.isEmpty()) {
            res.isReturning = res.unifiedProfileFound == true; // known in the unified profile even without a CRM account
            res.summary = res.unifiedProfileFound == true
                ? 'Known in the Data Cloud unified profile, no CRM purchase history yet.'
                : 'New prospect — not in unified profile, no account on file.';
            if (verified) addCrossAgentContext(res, email, null);   // a lead may still have a saved cart + coupon
            return res;
        }
        Account a = accs[0];
        res.preferences = String.isBlank(a.Coffee_Preferences__c) ? res.dataCloudPreferences : a.Coffee_Preferences__c;   // taste prefs are OK unverified — needed for recommendations
        res.emailConsent = a.Email_Consent__c == true;   // existing consent — agent must not re-ask if true
        res.customerStatus = String.isBlank(a.Customer_Status__c) ? 'Prospect' : a.Customer_Status__c;
        if (verified) {
            res.orderCount = [SELECT count() FROM Order WHERE AccountId = :a.Id];
            for (AggregateResult ar : [SELECT SUM(TotalAmount) s, MAX(EffectiveDate) d FROM Order WHERE AccountId = :a.Id]) {
                res.lifetimeValue = (Decimal) (ar.get('s') == null ? 0 : ar.get('s'));
                Object d = ar.get('d');
                res.lastOrderDate = d == null ? null : String.valueOf(d);
            }
        }
        if (verified) {
            Map<String, Decimal> qty = new Map<String, Decimal>();
            for (OrderItem oi : [SELECT Product2.Family, Quantity FROM OrderItem WHERE Order.AccountId = :a.Id]) {
                String f = String.isBlank(oi.Product2.Family) ? 'Coffee' : oi.Product2.Family;
                qty.put(f, (qty.get(f) == null ? 0 : qty.get(f)) + oi.Quantity);
            }
            Decimal best = -1;
            for (String f : qty.keySet()) if (qty.get(f) > best) { best = qty.get(f); res.favoriteCategory = f; }
        }
        Integer ordCnt = [SELECT count() FROM Order WHERE AccountId = :a.Id]; // boolean recognition only
        res.isReturning = ordCnt > 0 || res.unifiedProfileFound == true;
        String src = res.unifiedProfileFound == true ? ' [unified profile: matched]' : ' [unified profile: not matched]';
        String prefsNote = String.isBlank(res.preferences) ? ' [no saved preferences]'
            : ' [SAVED PREFERENCES — honor these, never recommend disliked items: ' + res.preferences + ']';
        if (verified) {
            res.summary = (res.orderCount > 0
                ? ('Returning ' + res.customerStatus + ': ' + res.orderCount + ' orders, LTV ' + res.lifetimeValue
                   + (res.favoriteCategory == null ? '' : ', loves ' + res.favoriteCategory) + '.')
                : 'Known prospect, no purchases yet.') + src + prefsNote;
            addAugmentedContext(res, a);
            addCrossAgentContext(res, email, a.Id);
        } else {
            // Unverified: recognize + use taste prefs for shopping, but WITHHOLD all PII.
            res.summary = (res.isReturning ? 'Returning customer (greet warmly).' : 'Known prospect.')
                + prefsNote
                + ' [IDENTITY NOT VERIFIED — order history, lifetime value, coupons, saved cart and cases are withheld. '
                + 'To share order/account details, ask the shopper to sign in: ' + IdentityService.LOGIN_URL + ']';
        }
        return res;
    }

    private static void addAugmentedContext(Result res, Account a) {
        if (a == null) return;
        res.dataCloudSegment = a.Data_Cloud_Segment__c;
        res.dataCloudChurnRisk = a.Data_Cloud_Churn_Risk__c;
        res.dataCloudNextBestAction = a.Data_Cloud_Next_Best_Action__c;
        res.dataCloudOrderCount = a.Data_Cloud_Order_Count__c == null ? null : a.Data_Cloud_Order_Count__c.intValue();
        res.dataCloudLifetimeValue = a.Data_Cloud_Lifetime_Value__c;
        res.dataCloudFavoriteCategory = a.Data_Cloud_Favorite_Category__c;
        res.dataCloudLastAugmentedAt = a.Data_Cloud_Last_Augmented_At__c == null ? null : String.valueOf(a.Data_Cloud_Last_Augmented_At__c);
        List<String> parts = new List<String>();
        if (String.isNotBlank(a.Data_Cloud_Profile_Summary__c)) parts.add(a.Data_Cloud_Profile_Summary__c);
        else {
            if (String.isNotBlank(res.dataCloudSegment)) parts.add('segment ' + res.dataCloudSegment);
            if (String.isNotBlank(res.dataCloudChurnRisk)) parts.add('risk ' + res.dataCloudChurnRisk);
            if (String.isNotBlank(res.dataCloudNextBestAction)) parts.add('next action: ' + res.dataCloudNextBestAction);
        }
        if (!parts.isEmpty()) {
            res.summary = (res.summary == null ? '' : res.summary)
                + ' || DATA CLOUD AUGMENTED CONTEXT: ' + String.join(parts, ' | ');
        }
    }

    /**
     * Cross-agent context — surfaces what OTHER agents have done so every agent stays context-aware:
     * a saved/abandoned cart (offer to restore), an unredeemed coupon, the most recent agent action,
     * and open support cases / returns (Service context). Appended to summary so agents use it with no
     * binding changes. Read-only.
     */
    private static void addCrossAgentContext(Result res, String email, Id accountId) {
        List<String> ctx = new List<String>();
        try {
            List<Cart__c> carts = [SELECT Status__c, Item_Count__c, Cart_Value__c FROM Cart__c
                WHERE Shopper_Email__c = :email AND Status__c IN ('Active','Abandoned') ORDER BY LastModifiedDate DESC LIMIT 1];
            if (!carts.isEmpty()) {
                Cart__c c = carts[0];
                Integer n = c.Item_Count__c == null ? 0 : c.Item_Count__c.intValue();
                res.hasSavedCart = true;
                res.savedCartSummary = c.Status__c + ' cart: ' + n + ' item(s), ' + (c.Cart_Value__c == null ? 0 : c.Cart_Value__c);
                ctx.add('SAVED ' + res.savedCartSummary + ' — OFFER TO RESTORE it');
            }
            List<Customer_Journey__c> js = [SELECT Coupon_Code__c, Coupon_Redeemed__c, Coupon_Discount_Percent__c, Last_Agent__c, Last_Stage__c
                FROM Customer_Journey__c WHERE Email__c = :email LIMIT 1];
            if (!js.isEmpty() && String.isNotBlank(js[0].Coupon_Code__c) && js[0].Coupon_Redeemed__c != true) {
                res.activeCouponCode = js[0].Coupon_Code__c;
                ctx.add('ACTIVE coupon ' + js[0].Coupon_Code__c + ' (' + js[0].Coupon_Discount_Percent__c + '% off, unredeemed) — remind them');
            }
            List<Agent_Interaction__c> ai = [SELECT Agent__c, Action__c, Result__c FROM Agent_Interaction__c
                WHERE Customer_Journey__r.Email__c = :email ORDER BY CreatedDate DESC LIMIT 1];
            if (!ai.isEmpty()) {
                res.lastAgentAction = ai[0].Agent__c + ': ' + ai[0].Action__c + (String.isBlank(ai[0].Result__c) ? '' : ' — ' + ai[0].Result__c);
                ctx.add('LAST AGENT ACTION → ' + res.lastAgentAction);
            }
            if (accountId != null) {
                Integer openCases = [SELECT count() FROM Case WHERE AccountId = :accountId AND IsClosed = false];
                if (openCases > 0) { res.openCaseCount = openCases; ctx.add(openCases + ' OPEN support case(s)'); }
                Integer ros = [SELECT count() FROM ReturnOrder WHERE AccountId = :accountId];
                if (ros > 0) ctx.add(ros + ' return(s) on file');
            }
        } catch (Exception e) { /* context is best-effort */ }
        if (!ctx.isEmpty()) res.summary = (res.summary == null ? '' : res.summary) + ' || CROSS-AGENT CONTEXT: ' + String.join(ctx, ' | ');
    }

    /**
     * D-2: query the Data Cloud unified profile synchronously to recognize a returning person by email
     * (ContactPointEmail joined to Unified Individual). Returns true if the email is in the unified profile.
     * Skipped in test context (ConnectApi Data Cloud query isn't available there) and fails soft to CRM.
     */
    private class DataCloudProfile {
        Boolean found = false;
        String individualId;
        String firstName;
        String coffeePreferences;
        String summary;
    }

    // The synchronous Data Cloud CdpQuery JOIN below hangs / times out (60-100s+) on this Developer Edition
    // org, which BLOCKS the live web chat on the verified path (the widget shows "Thinking" indefinitely and
    // never replies). CRM (Account/Order) already holds the customer + purchase data and dcUnifiedProfile()
    // fails soft to CRM anyway, so we skip the live Data Cloud enrichment here. Set to true again only on an
    // org where Data Cloud `queryAnsiSqlV2` returns promptly.
    @TestVisible private static Boolean DC_UNIFIED_PROFILE_ENABLED = false;

    private static DataCloudProfile dcUnifiedProfile(String email) {
        DataCloudProfile profile = new DataCloudProfile();
        if (!DC_UNIFIED_PROFILE_ENABLED || Test.isRunningTest() || String.isBlank(email)) return profile;
        try {
            String sql = 'SELECT cpe.ssot__EmailAddress__c em, ind.ssot__Id__c individualId, '
                + 'ind.ssot__FirstName__c firstName, ind.Coffee_Preferences__c coffeePreferences '
                + 'FROM ssot__ContactPointEmail__dlm cpe '
                + 'JOIN ssot__Individual__dlm ind ON ind.ssot__Id__c = cpe.ssot__PartyId__c '
                + 'WHERE cpe.ssot__EmailAddress__c = \'' + String.escapeSingleQuotes(email) + '\' LIMIT 1';
            ConnectApi.CdpQueryInput inp = new ConnectApi.CdpQueryInput();
            inp.sql = sql;
            ConnectApi.CdpQueryOutputV2 out = ConnectApi.CdpQuery.queryAnsiSqlV2(inp);
            if (out == null || out.data == null || out.data.isEmpty()) return profile;
            profile.found = true;
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(JSON.serialize(out.data));
            if (!rows.isEmpty()) {
                List<Object> row = (List<Object>) rows[0];
                // Query order: email, individualId, firstName, coffeePreferences.
                if (row.size() > 1 && row[1] != null) profile.individualId = String.valueOf(row[1]);
                if (row.size() > 2 && row[2] != null) profile.firstName = String.valueOf(row[2]);
                if (row.size() > 3 && row[3] != null) profile.coffeePreferences = String.valueOf(row[3]);
            }
            profile.summary = 'Data Cloud unified profile found'
                + (String.isBlank(profile.individualId) ? '' : ' [' + profile.individualId + ']')
                + (String.isBlank(profile.coffeePreferences) ? ' with no Data Cloud preferences.' : ' with Data Cloud preferences available.');
            return profile;
        } catch (Exception e) {
            return profile; // fail soft → CRM result stands
        }
    }
}
