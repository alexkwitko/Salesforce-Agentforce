/**
 * AbandonedCartService — Phase 5 orchestration + identity/dedup.
 * When a cart is marked Abandoned (1h after inactivity with no order), decide:
 *   - KNOWN customer (Person Account exists by email)  -> link cart to that customer, NO lead.
 *   - EXISTING lead (same email)                       -> update that lead's cart info.
 *   - NEW shopper                                      -> create a Lead for Agent 1 (Inside Sales).
 * Identity key = email. Invocable so a record-triggered Flow (or agent) can call it.
 */
public with sharing class AbandonedCartService {

    public class Request {
        @InvocableVariable(label='Cart ID' required=true) public Id cartId;
    }
    public class Result {
        @InvocableVariable public Id leadId;
        @InvocableVariable public Boolean leadCreated;
        @InvocableVariable public String outcome;
    }

    @InvocableMethod(label='Process Abandoned Cart'
        description='Dedupes a cart by email and either links it to a known customer or creates an inside-sales Lead.')
    public static List<Result> processAbandonedCart(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) out.add(process(r.cartId));
        return out;
    }

    public static Result process(Id cartId) {
        Result res = new Result();
        res.leadCreated = false;

        Cart__c cart = [
            SELECT Id, Shopper_Email__c, Shopper_Name__c, Cart_Value__c, Item_Count__c,
                   Customer__c, Lead__c, Status__c, Woo_Cart_Id__c, Email_Consent__c
            FROM Cart__c WHERE Id = :cartId LIMIT 1
        ];
        Boolean cartConsent = (cart.Email_Consent__c == true);

        String email = cart.Shopper_Email__c;
        if (String.isBlank(email)) {
            res.outcome = 'No shopper email on cart; cannot route.';
            return res;
        }

        // Known customer? (Person Account by email). BOTH known and unknown shoppers get a Lead;
        // the difference is that a KNOWN customer's lead is related to their Person Account.
        List<Account> known = [
            SELECT Id, Email_Consent__c FROM Account WHERE PersonEmail = :email AND IsPersonAccount = true LIMIT 1
        ];
        Id accountId = known.isEmpty() ? null : known[0].Id;
        Boolean isKnown = accountId != null;
        // A KNOWN customer who consented at the account level is consented for cart recovery, even if
        // the transient storefront cart didn't carry the flag. Never auto-grant for unknown shoppers.
        Boolean consent = cartConsent || (isKnown && known[0].Email_Consent__c == true);

        // Existing open lead by email? update it; else create a new one.
        List<Lead> existing = [
            SELECT Id FROM Lead WHERE Email = :email AND IsConverted = false LIMIT 1
        ];
        Lead l;
        if (!existing.isEmpty()) {
            l = new Lead(Id = existing[0].Id, Cart_Status__c = 'Abandoned',
                         Last_Cart_Value__c = cart.Cart_Value__c);
            if (isKnown) l.Person_Account__c = accountId;
            if (consent) l.Email_Consent__c = true;   // never auto-revoke
            update l;
            res.outcome = isKnown
                ? 'Existing lead updated (known customer — linked to Person Account).'
                : 'Existing lead updated with new abandoned cart.';
        } else {
            String fullName = String.isBlank(cart.Shopper_Name__c) ? 'Coffee Shopper' : cart.Shopper_Name__c;
            String firstName, lastName;
            if (fullName.contains(' ')) { firstName = fullName.substringBefore(' '); lastName = fullName.substringAfter(' '); }
            else { firstName = null; lastName = fullName; }
            l = new Lead(
                FirstName = firstName,
                LastName = lastName,
                Company = isKnown ? 'Existing Customer' : 'Online Shopper',
                Email = email,
                LeadSource = 'WooCommerce Abandoned Cart',
                Status = 'Open - Not Contacted',
                Cart_Status__c = 'Abandoned',
                Last_Cart_Value__c = cart.Cart_Value__c,
                Email_Consent__c = consent,
                Person_Account__c = accountId
            );
            insert l;
            res.leadCreated = true;
            res.outcome = isKnown
                ? 'New lead created for known customer (linked to Person Account).'
                : 'New lead created for inside-sales follow-up.';
        }

        // Link the cart to the lead (always) and to the Person Account (when known).
        update new Cart__c(Id = cart.Id, Lead__c = l.Id, Customer__c = accountId, Status__c = 'Abandoned');
        res.leadId = l.Id;
        return res;
    }
}
