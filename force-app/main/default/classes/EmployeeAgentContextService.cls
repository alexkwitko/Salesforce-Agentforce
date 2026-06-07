/**
 * EmployeeAgentContextService
 * Agentforce action wrapper for trusted employee-agent record workflows.
 *
 * AgentContextService intentionally accepts recordId as text so web/chat actions can keep
 * a narrow schema. Employee agents need a native Salesforce Id input so Agentforce can bind
 * the record parameter reliably. This wrapper preserves the shared context envelope while
 * giving Inside Sales and Post-Purchase Growth a record-id action contract.
 */
public without sharing class EmployeeAgentContextService {
    public class Request {
        @InvocableVariable(label='Record Id' description='Lead or Order record Id for the employee agent workflow.' required=true)
        public Id recordId;

        @InvocableVariable(label='Agent Name' description='Optional agent developer name. Inferred from the record type when omitted.')
        public String agentName;

        @InvocableVariable(label='Intent' description='Current employee-agent intent.')
        public String intent;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public Boolean identityVerified;
        @InvocableVariable public Boolean safeToUsePrivateContext;
        @InvocableVariable public String privacyMode;
        @InvocableVariable public String email;
        @InvocableVariable public String contextSource;
        @InvocableVariable public String handoffTarget;
        @InvocableVariable public String handoffReason;
        @InvocableVariable public Boolean emailConsent;
        @InvocableVariable public String activeCouponCode;
        @InvocableVariable public String lastAgentAction;
        @InvocableVariable public Integer openCaseCount;
        @InvocableVariable public String dataCloudSegment;
        @InvocableVariable public String dataCloudChurnRisk;
        @InvocableVariable public String dataCloudNextBestAction;
        @InvocableVariable public Integer dataCloudOrderCount;
        @InvocableVariable public Decimal dataCloudLifetimeValue;
        @InvocableVariable public String dataCloudFavoriteCategory;
        @InvocableVariable public String summary;
        @InvocableVariable public String contextJson;
    }

    @InvocableMethod(label='Get Employee Agent Context'
        description='Returns the shared privacy-gated context packet for a trusted employee Lead or Order workflow.')
    public static List<Result> getContext(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) out.add(run(r));
        return out;
    }

    private static Result run(Request r) {
        AgentContextService.Request sr = new AgentContextService.Request();
        sr.recordId = r == null || r.recordId == null ? null : String.valueOf(r.recordId);
        sr.recordScopedContext = true;
        sr.agentName = String.isBlank(r == null ? null : r.agentName) ? inferAgentName(r == null ? null : r.recordId) : r.agentName;
        sr.intent = String.isBlank(r == null ? null : r.intent) ? inferIntent(r == null ? null : r.recordId) : r.intent;

        AgentContextService.Result base = AgentContextService.getContext(new List<AgentContextService.Request>{ sr })[0];
        Result res = new Result();
        res.success = base.success;
        res.identityVerified = base.identityVerified;
        res.safeToUsePrivateContext = base.safeToUsePrivateContext;
        res.privacyMode = base.privacyMode;
        res.email = base.email;
        res.contextSource = base.contextSource;
        res.handoffTarget = base.handoffTarget;
        res.handoffReason = base.handoffReason;
        res.emailConsent = base.emailConsent;
        res.activeCouponCode = base.activeCouponCode;
        res.lastAgentAction = base.lastAgentAction;
        res.openCaseCount = base.openCaseCount;
        res.dataCloudSegment = base.dataCloudSegment;
        res.dataCloudChurnRisk = base.dataCloudChurnRisk;
        res.dataCloudNextBestAction = base.dataCloudNextBestAction;
        res.dataCloudOrderCount = base.dataCloudOrderCount;
        res.dataCloudLifetimeValue = base.dataCloudLifetimeValue;
        res.dataCloudFavoriteCategory = base.dataCloudFavoriteCategory;
        res.summary = base.summary;
        res.contextJson = base.contextJson;
        return res;
    }

    private static String inferAgentName(Id recordId) {
        if (recordId == null) return null;
        if (recordId.getSObjectType() == Lead.SObjectType) return 'Inside_Sales';
        if (recordId.getSObjectType() == Order.SObjectType) return 'Post_Purchase_Growth';
        return null;
    }

    private static String inferIntent(Id recordId) {
        if (recordId == null) return null;
        if (recordId.getSObjectType() == Lead.SObjectType) return 'cart recovery';
        if (recordId.getSObjectType() == Order.SObjectType) return 'post purchase offer';
        return null;
    }
}
