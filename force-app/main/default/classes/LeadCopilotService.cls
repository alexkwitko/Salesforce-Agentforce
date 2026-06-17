/**
 * LeadCopilotService — the autonomous lead-nurture brain (pure logic; no @InvocableMethod here).
 *
 * Two responsibilities, exposed as plain static methods so the scheduled sweep can call them
 * headlessly. Agent/Flow-callable wrappers live in LeadCopilotMarkAction and LeadCopilotStepAction
 * (Apex permits only one @InvocableMethod per class).
 *
 *   1. markNurture    — hand a lead off to the Nurture track (status + Nurture_Since__c stamp).
 *   2. runNurtureStep — derive a next-best-action from the lead's unified-profile metrics
 *                       (LTV, purchases, recency, cart), record it, send the personalized email,
 *                       and stamp Nurture_Last_Run__c.
 *
 * Design rule: scalar logic only (no list/dict outputs) so the agent's apply_actions topic stays valid.
 */
public without sharing class LeadCopilotService {

    public static final String STATUS_NURTURE = 'Nurture';

    public class StepResult {
        public String nextBestAction;
        public Boolean emailSent = false;
        public String message;
        public Boolean success = false;
    }

    /** Move open (unconverted) leads into Nurture and stamp the start date. Idempotent. */
    public static Integer markNurture(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) return 0;
        List<Lead> toUpdate = new List<Lead>();
        for (Lead l : [
            SELECT Id, Status, IsConverted, Nurture_Since__c
            FROM Lead WHERE Id IN :leadIds AND IsConverted = false
        ]) {
            if (l.Status != STATUS_NURTURE) {
                l.Status = STATUS_NURTURE;
                l.Nurture_Since__c = Date.today();
                toUpdate.add(l);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        return toUpdate.size();
    }

    /** Compute the recommendation from profile metrics, persist it, send the email, stamp the run date. */
    public static StepResult runNurtureStep(Id leadId) {
        StepResult res = new StepResult();
        if (leadId == null) { res.message = 'No lead id.'; return res; }

        List<Lead> ls = [
            SELECT Id, FirstName, Status, IsConverted, Email, Email_Consent__c,
                   Lifetime_Order_Value__c, Last_Purchase_Date__c,
                   Cart_Status__c, Last_Cart_Value__c, ProductInterest__c,
                   Chat_Interest__c, Preferences__c
            FROM Lead WHERE Id = :leadId LIMIT 1
        ];
        if (ls.isEmpty()) { res.message = 'Lead not found.'; return res; }
        Lead l = ls[0];

        if (l.IsConverted || l.Status == 'Closed - Converted') {
            res.message = 'Lead already converted — no nurture needed.';
            res.success = true;
            return res;
        }

        String nba = recommend(l);
        res.nextBestAction = nba;

        update new Lead(Id = l.Id, Next_Best_Action__c = nba, Nurture_Last_Run__c = Date.today());

        if (l.Email_Consent__c != true || String.isBlank(l.Email)) {
            res.message = 'Recommendation saved; no email (no consent or no address).';
            res.success = true;
            return res;
        }

        Decimal cart = l.Last_Cart_Value__c == null ? 0 : l.Last_Cart_Value__c;
        Boolean hasCart = (l.Cart_Status__c == 'abandoned' || l.Cart_Status__c == 'Abandoned') && cart > 0;

        try {
            if (hasCart) {
                // abandoned cart -> the cart-recovery offer (real coupon + saved items)
                LeadNurtureService.Result nr = LeadNurtureService.run(l.Id);
                res.emailSent = (nr != null && nr.success == true);
                res.message = (nr != null ? nr.message : 'Cart-recovery email attempted.');
            } else {
                // no cart -> general personalized nurture email via the consent-gated Salesforce
                // sender (reliably delivers to Gmail; subject to the 15/day DE cap until an
                // authenticated SMTP relay is configured — see WordPressMailService).
                EmailService.Request er = new EmailService.Request();
                er.toEmail = l.Email;
                er.subject = nurtureSubject(l);
                er.htmlBody = nurtureBody(l);
                er.recordId = l.Id;          // EmailService re-checks consent on this record
                er.isTransactional = false;  // marketing
                List<EmailService.Response> ers = EmailService.send(new List<EmailService.Request>{ er });
                res.emailSent = (!ers.isEmpty() && ers[0].success == true);
                res.message = (!ers.isEmpty() ? ers[0].message : 'Nurture email attempted.');
            }
        } catch (Exception e) {
            res.message = 'Recommendation saved; email failed: ' + e.getMessage();
        }
        res.success = true;
        return res;
    }

    private static String firstName(Lead l) {
        return String.isNotBlank(l.FirstName) ? l.FirstName : 'there';
    }

    /** Customer-facing subject by segment (no fabricated coupon codes). */
    private static String nurtureSubject(Lead l) {
        Decimal ltv = l.Lifetime_Order_Value__c == null ? 0 : l.Lifetime_Order_Value__c;
        if (ltv >= 100) return 'A little something for one of our favorite customers ☕';
        if (l.Last_Purchase_Date__c != null) return 'We miss you at Kwitko Coffee — come back for a fresh cup';
        return 'Find your perfect Kwitko coffee ☕';
    }

    /** Customer-facing HTML nurture body, personalized by name + interest + segment. */
    private static String nurtureBody(Lead l) {
        Decimal ltv = l.Lifetime_Order_Value__c == null ? 0 : l.Lifetime_Order_Value__c;
        String interest = String.isNotBlank(l.ProductInterest__c) ? l.ProductInterest__c
                          : (String.isNotBlank(l.Chat_Interest__c) ? l.Chat_Interest__c : null);
        String hook;
        if (ltv >= 100) {
            hook = 'As one of our most valued customers, we\'d love to keep your favorites coming. '
                 + 'Tell us what you\'re in the mood for and we\'ll line up a personalized pick just for you.';
        } else if (l.Last_Purchase_Date__c != null) {
            hook = 'It\'s been a little while since your last order, and your next great cup is waiting. '
                 + 'Come back and rediscover the roasts you loved — plus a few new ones we think you\'ll enjoy.';
        } else {
            hook = 'New to Kwitko? Let\'s find the coffee you\'ll look forward to every morning. '
                 + 'Our best-sellers are a great place to start, and we\'re happy to recommend based on your taste.';
        }
        String interestLine = interest != null
            ? '<p>You mentioned an interest in <strong>' + String.escapeSingleQuotes(interest) + '</strong> — we have some great options there.</p>'
            : '';
        return '<p>Hi ' + String.escapeSingleQuotes(firstName(l)) + ',</p>'
             + '<p>' + hook + '</p>'
             + interestLine
             + '<p>Ready when you are — just reply to this email or visit the shop and we\'ll help you find your perfect cup.</p>'
             + '<p>— The Kwitko Coffee Co. team</p>';
    }

    /** Scalar next-best-action from the lead's profile metrics. */
    private static String recommend(Lead l) {
        Decimal ltv  = l.Lifetime_Order_Value__c == null ? 0 : l.Lifetime_Order_Value__c;
        Decimal cart = l.Last_Cart_Value__c == null ? 0 : l.Last_Cart_Value__c;
        Boolean abandoned = (l.Cart_Status__c == 'abandoned' || l.Cart_Status__c == 'Abandoned');
        String interest = String.isNotBlank(l.ProductInterest__c) ? l.ProductInterest__c
                          : (String.isNotBlank(l.Chat_Interest__c) ? l.Chat_Interest__c : null);
        String tail = interest != null ? ' Lead with their interest: ' + interest + '.' : '';

        if (abandoned && cart > 0) {
            return 'Recover the abandoned cart ($' + cart.setScale(2) + ') — send a time-limited discount + the saved items.' + tail;
        }
        if (ltv >= 100) {
            return 'High-value lead (LTV $' + ltv.setScale(2) + ') — offer a VIP/loyalty incentive and a personalized recommendation.' + tail;
        }
        if (l.Last_Purchase_Date__c != null) {
            return 'Lapsed buyer (last purchase ' + l.Last_Purchase_Date__c.format() + ') — send a win-back offer on a past favorite.' + tail;
        }
        if (ltv > 0) {
            return 'Engaged lead (LTV $' + ltv.setScale(2) + ') — recommend a best-seller bundle with a first-reorder incentive.' + tail;
        }
        return 'Cold lead — send an intro offer with the best-seller recommendation to drive a first purchase.' + tail;
    }
}
