/**
 * AgentContextService
 * One shared, privacy-gated context envelope for all Agentforce agents.
 *
 * The goal is simple: every agent starts from the same customer/journey state, uses the
 * same identity gate, and hands off with a compact packet instead of asking the shopper
 * to repeat themselves or guessing from stale context.
 */
public without sharing class AgentContextService {
    private static final Set<String> RECORD_SCOPED_AGENTS = new Set<String>{
        'Inside_Sales',
        'Post_Purchase_Growth'
    };

    public class Request {
        @InvocableVariable(label='Email' description='Shopper/customer email when known.')
        public String email;

        @InvocableVariable(label='Verified Email' description='Pass loggedInEmail for web/chat. Empty means unverified shopper context.')
        public String verifiedEmail;

        @InvocableVariable(label='Agent Name' description='Agent developer name, for routing and record-scoped safeguards.')
        public String agentName;

        @InvocableVariable(label='Intent' description='Current user intent, e.g. order status, cart recovery, recommendation.')
        public String intent;

        @InvocableVariable(label='Record Id' description='Salesforce Lead or Order Id for trusted employee-agent workflows.')
        public String recordId;

        @InvocableVariable(label='Record Scoped Context' description='True only for trusted employee agents processing the supplied Salesforce record id. Do not expose this input on web chat actions.')
        public Boolean recordScopedContext;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public Boolean identityVerified;
        @InvocableVariable public Boolean safeToUsePrivateContext;
        @InvocableVariable public Boolean mustAskForSignIn;
        @InvocableVariable public String privacyMode;
        @InvocableVariable public String email;
        @InvocableVariable public String contextSource;
        @InvocableVariable public String handoffTarget;
        @InvocableVariable public String handoffReason;
        @InvocableVariable public Boolean isReturning;
        @InvocableVariable public String customerStatus;
        @InvocableVariable public String preferences;
        @InvocableVariable public Boolean emailConsent;
        @InvocableVariable public Boolean hasSavedCart;
        @InvocableVariable public String savedCartSummary;
        @InvocableVariable public String activeCouponCode;
        @InvocableVariable public String lastAgentAction;
        @InvocableVariable public Integer openCaseCount;
        @InvocableVariable public String journeyId;
        @InvocableVariable public String lastStage;
        @InvocableVariable public String lastAgent;
        @InvocableVariable public String recommendedProductIds;
        @InvocableVariable public String purchasedProductIds;
        @InvocableVariable public String postPurchaseDoneOrderIds;
        @InvocableVariable public String dataCloudSegment;
        @InvocableVariable public String dataCloudChurnRisk;
        @InvocableVariable public String dataCloudNextBestAction;
        @InvocableVariable public Integer dataCloudOrderCount;
        @InvocableVariable public Decimal dataCloudLifetimeValue;
        @InvocableVariable public String dataCloudFavoriteCategory;
        @InvocableVariable public String summary;
        @InvocableVariable public String contextJson;
    }

    private class IdentityResolution {
        String email;
        String source;
        Boolean trustedRecordContext = false;
    }

    @InvocableMethod(label='Get Shared Agent Context'
        description='Returns a shared privacy-gated customer/journey context packet. Call first in every agent/subagent and before handoff.')
    public static List<Result> getContext(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r));
        return out;
    }

    private static Result build(Request r) {
        Result res = new Result();
        res.success = false;
        res.identityVerified = false;
        res.safeToUsePrivateContext = false;
        res.mustAskForSignIn = false;

        IdentityResolution identity = resolveIdentity(r);
        res.email = identity.email;
        res.contextSource = identity.source;
        if (String.isBlank(identity.email)) {
            res.summary = 'No customer identity available yet. Ask for email, or wait for verified website sign-in.';
            res.handoffTarget = routeTarget(r);
            res.handoffReason = routeReason(res.handoffTarget);
            res.contextJson = JSON.serialize(new Map<String, Object>{
                'success' => false,
                'reason' => 'no_identity',
                'handoffTarget' => res.handoffTarget
            });
            return res;
        }

        String agentName = cleanAgentName(r == null ? null : r.agentName);
        if (String.isBlank(agentName)) agentName = inferTrustedAgentName(r == null ? null : r.recordId);
        Boolean trustedRecordContext = identity.trustedRecordContext == true
            && RECORD_SCOPED_AGENTS.contains(agentName);
        res.identityVerified = trustedRecordContext || IdentityService.isVerified(identity.email, r == null ? null : r.verifiedEmail);
        res.safeToUsePrivateContext = res.identityVerified;
        res.mustAskForSignIn = !res.identityVerified;
        res.privacyMode = trustedRecordContext ? 'trusted_internal_record'
            : (res.identityVerified ? 'verified_shopper' : 'unverified_shopper');

        CustomerLookupService.Request lr = new CustomerLookupService.Request();
        lr.email = identity.email;
        lr.verifiedEmail = trustedRecordContext ? identity.email : (r == null ? null : r.verifiedEmail);
        CustomerLookupService.Result customer = CustomerLookupService.lookup(new List<CustomerLookupService.Request>{ lr })[0];

        copyCustomerFields(res, customer);
        if (res.identityVerified) copyJourneyFields(res, identity.email);
        else clearPrivateFields(res);

        res.handoffTarget = routeTarget(r);
        res.handoffReason = routeReason(res.handoffTarget);
        res.success = true;
        res.summary = buildSummary(res, customer);
        res.contextJson = buildContextJson(res);
        return res;
    }

    private static IdentityResolution resolveIdentity(Request r) {
        IdentityResolution out = new IdentityResolution();
        if (r == null) {
            out.source = 'none';
            return out;
        }
        if (String.isNotBlank(r.email)) {
            out.email = r.email.trim();
            out.source = 'email';
            return out;
        }
        if (String.isNotBlank(r.verifiedEmail)) {
            out.email = r.verifiedEmail.trim();
            out.source = 'verifiedEmail';
            return out;
        }
        if ((r.recordScopedContext == true || canInferRecordScopedContext(r)) && String.isNotBlank(r.recordId)) {
            try {
                Id rid = (Id) r.recordId.trim();
                if (rid.getSObjectType() == Lead.SObjectType) {
                    List<Lead> leads = [SELECT Email FROM Lead WHERE Id = :rid LIMIT 1];
                    if (!leads.isEmpty() && String.isNotBlank(leads[0].Email)) {
                        out.email = leads[0].Email.trim();
                        out.source = 'leadRecord';
                        out.trustedRecordContext = true;
                    }
                } else if (rid.getSObjectType() == Order.SObjectType) {
                    List<Order> orders = [SELECT Account.PersonEmail FROM Order WHERE Id = :rid LIMIT 1];
                    if (!orders.isEmpty() && String.isNotBlank(orders[0].Account.PersonEmail)) {
                        out.email = orders[0].Account.PersonEmail.trim();
                        out.source = 'orderRecord';
                        out.trustedRecordContext = true;
                    }
                }
            } catch (Exception e) {
                out.source = 'invalidRecord';
            }
        }
        if (String.isBlank(out.source)) out.source = 'none';
        return out;
    }

    private static void copyCustomerFields(Result res, CustomerLookupService.Result customer) {
        res.isReturning = customer.isReturning;
        res.customerStatus = customer.customerStatus;
        res.preferences = customer.preferences;
        res.emailConsent = customer.emailConsent;
        if (res.identityVerified) {
            res.hasSavedCart = customer.hasSavedCart;
            res.savedCartSummary = customer.savedCartSummary;
            res.activeCouponCode = customer.activeCouponCode;
            res.lastAgentAction = customer.lastAgentAction;
            res.openCaseCount = customer.openCaseCount;
            res.dataCloudSegment = customer.dataCloudSegment;
            res.dataCloudChurnRisk = customer.dataCloudChurnRisk;
            res.dataCloudNextBestAction = customer.dataCloudNextBestAction;
            res.dataCloudOrderCount = customer.dataCloudOrderCount;
            res.dataCloudLifetimeValue = customer.dataCloudLifetimeValue;
            res.dataCloudFavoriteCategory = customer.dataCloudFavoriteCategory;
        }
    }

    private static void copyJourneyFields(Result res, String email) {
        JourneyService.StateRequest sr = new JourneyService.StateRequest();
        sr.email = email;
        JourneyService.State state = JourneyService.getJourneyState(new List<JourneyService.StateRequest>{ sr })[0];
        if (state == null || state.found != true) return;
        res.journeyId = state.journeyId;
        res.lastStage = state.lastStage;
        res.lastAgent = state.lastAgent;
        res.recommendedProductIds = state.recommendedProductIds;
        res.purchasedProductIds = state.purchasedProductIds;
        res.postPurchaseDoneOrderIds = state.postPurchaseDoneOrderIds;
    }

    private static void clearPrivateFields(Result res) {
        res.hasSavedCart = null;
        res.savedCartSummary = null;
        res.activeCouponCode = null;
        res.lastAgentAction = null;
        res.openCaseCount = null;
        res.journeyId = null;
        res.lastStage = null;
        res.lastAgent = null;
        res.recommendedProductIds = null;
        res.purchasedProductIds = null;
        res.postPurchaseDoneOrderIds = null;
        res.dataCloudSegment = null;
        res.dataCloudChurnRisk = null;
        res.dataCloudNextBestAction = null;
        res.dataCloudOrderCount = null;
        res.dataCloudLifetimeValue = null;
        res.dataCloudFavoriteCategory = null;
    }

    private static String buildSummary(Result res, CustomerLookupService.Result customer) {
        List<String> parts = new List<String>();
        parts.add('SHARED AGENT CONTEXT');
        parts.add('privacy=' + res.privacyMode);
        parts.add('handoff=' + res.handoffTarget);
        if (res.identityVerified) {
            if (String.isNotBlank(res.lastAgentAction)) parts.add('last action: ' + res.lastAgentAction);
            if (String.isNotBlank(res.lastStage)) parts.add('last stage: ' + res.lastStage);
            if (String.isNotBlank(res.dataCloudNextBestAction)) parts.add('Data Cloud next action: ' + res.dataCloudNextBestAction);
            if (customer != null && customer.isMultiBrand == true) {
                parts.add('MULTI-BRAND customer (shops more than one of our stores'
                    + (String.isBlank(customer.brandsPurchased) ? '' : ': ' + customer.brandsPurchased)
                    + ') — OK to acknowledge the cross-brand relationship and cross-recommend coffee<->equipment');
            }
        } else {
            parts.add('PRIVATE CONTEXT WITHHELD until verified website sign-in');
        }
        if (customer != null && String.isNotBlank(customer.summary)) parts.add(customer.summary);
        return String.join(parts, ' | ');
    }

    private static String buildContextJson(Result res) {
        Map<String, Object> payload = new Map<String, Object>{
            'success' => res.success,
            'privacyMode' => res.privacyMode,
            'identityVerified' => res.identityVerified,
            'safeToUsePrivateContext' => res.safeToUsePrivateContext,
            'mustAskForSignIn' => res.mustAskForSignIn,
            'email' => res.email,
            'contextSource' => res.contextSource,
            'handoffTarget' => res.handoffTarget,
            'handoffReason' => res.handoffReason,
            'isReturning' => res.isReturning,
            'customerStatus' => res.customerStatus,
            'preferences' => res.preferences,
            'emailConsent' => res.emailConsent
        };
        if (res.identityVerified) {
            payload.put('hasSavedCart', res.hasSavedCart);
            payload.put('savedCartSummary', res.savedCartSummary);
            payload.put('activeCouponCode', res.activeCouponCode);
            payload.put('lastAgentAction', res.lastAgentAction);
            payload.put('openCaseCount', res.openCaseCount);
            payload.put('journeyId', res.journeyId);
            payload.put('lastStage', res.lastStage);
            payload.put('lastAgent', res.lastAgent);
            payload.put('recommendedProductIds', res.recommendedProductIds);
            payload.put('purchasedProductIds', res.purchasedProductIds);
            payload.put('postPurchaseDoneOrderIds', res.postPurchaseDoneOrderIds);
            payload.put('dataCloudSegment', res.dataCloudSegment);
            payload.put('dataCloudChurnRisk', res.dataCloudChurnRisk);
            payload.put('dataCloudNextBestAction', res.dataCloudNextBestAction);
            payload.put('dataCloudOrderCount', res.dataCloudOrderCount);
            payload.put('dataCloudLifetimeValue', res.dataCloudLifetimeValue);
            payload.put('dataCloudFavoriteCategory', res.dataCloudFavoriteCategory);
        } else {
            payload.put('privateContext', 'withheld_until_verified_sign_in');
        }
        return JSON.serialize(payload);
    }

    private static String routeTarget(Request r) {
        String agentName = cleanAgentName(r == null ? null : r.agentName);
        if (String.isBlank(agentName)) agentName = inferTrustedAgentName(r == null ? null : r.recordId);
        String haystack = ((r == null ? '' : String.valueOf(r.intent)) + ' '
            + agentName).toLowerCase();
        if (containsAny(haystack, new List<String>{'order','shipping','tracking','delivery','return','refund','cancel','case','support','human','lost','damaged'})) {
            return 'Service';
        }
        if (containsAny(haystack, new List<String>{'abandoned','cart recovery','recovery','lead','inside sales','inside_sales'})) {
            return 'Inside_Sales';
        }
        if (containsAny(haystack, new List<String>{'post purchase','post-purchase','post_purchase_growth','buy again','growth','after purchase'})) {
            return 'Post_Purchase_Growth';
        }
        if (containsAny(haystack, new List<String>{'recommend','product','product_advisor','advisor','strategy','discount'})) {
            return 'Product_Advisor';
        }
        return 'Kwitko_Concierge';
    }

    private static String routeReason(String target) {
        if (target == 'Service') return 'The intent is about orders, fulfillment, shipping, returns, refunds, cases, or human support.';
        if (target == 'Inside_Sales') return 'The intent is abandoned-cart or lead recovery.';
        if (target == 'Post_Purchase_Growth') return 'The intent is a post-purchase buy-again offer.';
        if (target == 'Product_Advisor') return 'The intent is product recommendation, strategy, or discount guidance.';
        return 'The intent is general shopping concierge.';
    }

    private static Boolean containsAny(String haystack, List<String> needles) {
        if (String.isBlank(haystack)) return false;
        for (String n : needles) if (haystack.contains(n)) return true;
        return false;
    }

    private static String cleanAgentName(String agentName) {
        return String.isBlank(agentName) ? '' : agentName.trim();
    }

    private static Boolean canInferRecordScopedContext(Request r) {
        if (r == null || String.isBlank(r.recordId)) return false;
        if (String.isNotBlank(r.email) || String.isNotBlank(r.verifiedEmail)) return false;
        String agentName = cleanAgentName(r.agentName);
        return String.isBlank(agentName) || RECORD_SCOPED_AGENTS.contains(agentName);
    }

    private static String inferTrustedAgentName(String recordId) {
        if (String.isBlank(recordId)) return '';
        try {
            Id rid = (Id) recordId.trim();
            if (rid.getSObjectType() == Lead.SObjectType) return 'Inside_Sales';
            if (rid.getSObjectType() == Order.SObjectType) return 'Post_Purchase_Growth';
        } catch (Exception e) {
            return '';
        }
        return '';
    }
}
