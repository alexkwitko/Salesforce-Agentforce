/**
 * SubscriptionConciergeService — shared helpers for the RLM Subscription
 * Lifecycle Concierge agent actions. (Salesforce allows only one
 * @InvocableMethod per class, so each action lives in its own class and
 * calls into these helpers.)
 *
 * Subscriptions are modeled on the standard Asset object (RLM's install-base
 * object), priced from RLM ProductSellingModel + PricebookEntry. The engine's
 * AssetStatePeriod/AssetAction are written only by the Place Quote/Order
 * pipeline (needs org-level "Enable Revenue Cloud Features"); until then these
 * actions keep current state on the Asset. To upgrade, swap the DML for a Place
 * Quote callout — action signatures are unchanged, so the agent does not change.
 */
public with sharing class SubscriptionConciergeService {

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
        @InvocableVariable(label='Subscription Id') public String subscriptionId;
    }

    public static Id resolveAccount(String accountId, String email) {
        if (String.isNotBlank(accountId)) {
            try { return (Id) accountId; } catch (Exception e) { /* fall through */ }
        }
        if (String.isNotBlank(email)) {
            List<Contact> cs = [SELECT AccountId FROM Contact WHERE Email = :email AND AccountId != null LIMIT 1];
            if (!cs.isEmpty()) return cs[0].AccountId;
            List<Account> accs = [SELECT Id FROM Account WHERE Name = :email LIMIT 1];
            if (!accs.isEmpty()) return accs[0].Id;
        }
        return null;
    }

    public static Asset resolveSubscription(String subscriptionId, String email) {
        if (String.isNotBlank(subscriptionId)) {
            List<Asset> a = [SELECT Id, Name, Quantity, Price, Status, UsageEndDate FROM Asset WHERE Id = :subscriptionId LIMIT 1];
            if (!a.isEmpty()) return a[0];
        }
        if (String.isNotBlank(email)) {
            Id acct = resolveAccount(null, email);
            if (acct != null) {
                List<Asset> a = [SELECT Id, Name, Quantity, Price, Status, UsageEndDate FROM Asset
                                 WHERE AccountId = :acct AND Status != 'Obsolete' ORDER BY InstallDate DESC LIMIT 1];
                if (!a.isEmpty()) return a[0];
            }
        }
        return null;
    }

    /**
     * Identity gate for customer-web subscription actions. Returns null when the caller is verified
     * (Tier-1 logged-in email match, or Tier-2 OTP proof), otherwise the sign-in message to narrate.
     * Internal/trusted agents satisfy this by passing the customer's email as BOTH email and verifiedEmail.
     */
    public static String gate(String email, String verifiedEmail) {
        return IdentityService.isVerified(email, verifiedEmail) ? null : IdentityService.signInMessage();
    }

    /**
     * Ownership-scoped resolver: only returns the subscription (Asset) if it belongs to the account of
     * the (verified) email — closes the IDOR hole where a caller could pass any subscriptionId. When no
     * subscriptionId is given, returns the caller's latest active subscription.
     */
    public static Asset resolveOwnedSubscription(String subscriptionId, String email) {
        Id acct = resolveAccount(null, email);
        if (acct == null) return null;
        if (String.isNotBlank(subscriptionId)) {
            List<Asset> a = [SELECT Id, Name, Quantity, Price, Status, UsageEndDate, AccountId
                             FROM Asset WHERE Id = :subscriptionId AND AccountId = :acct LIMIT 1];
            return a.isEmpty() ? null : a[0];
        }
        List<Asset> a = [SELECT Id, Name, Quantity, Price, Status, UsageEndDate FROM Asset
                         WHERE AccountId = :acct AND Status != 'Obsolete' ORDER BY InstallDate DESC LIMIT 1];
        return a.isEmpty() ? null : a[0];
    }

    public static String money(Decimal d) { return d == null ? '$0' : '$' + d.setScale(2).format(); }
    public static String dt(Date d) { return d == null ? 'n/a' : d.format(); }
}
