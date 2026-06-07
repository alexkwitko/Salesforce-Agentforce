/**
 * CaseResolutionService — a REAL fix tool: closes a support case with a resolution summary and records
 * who resolved it, so the service agent can actually RESOLVE issues (not just open/audit them) and the
 * resolution is traceable + visible to every other agent via the journey log.
 */
public without sharing class CaseResolutionService {

    public class Request {
        @InvocableVariable(label='Case Number' required=true) public String caseNumber;
        @InvocableVariable(label='Resolution (what was done to fix it)') public String resolution;
        @InvocableVariable(label='Confirmed by Agent' description='Must be true only when the issue is actually fixed and the case should be closed.') public Boolean confirmed;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Resolve Case'
        description='Closes a support case with a resolution summary and records who resolved it. Use ONLY when the issue is actually fixed.')
    public static List<Result> resolve(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doResolve(r));
        return out;
    }

    private static Result doResolve(Request r) {
        Result res = new Result(); res.success = false;
        if (String.isBlank(r.caseNumber)) { res.message = 'Need a case number to resolve.'; return res; }
        if (r.confirmed != true) { res.message = 'Confirm the issue is actually fixed before closing the case.'; return res; }
        List<Case> cs = [SELECT Id, Status, CaseNumber, Account.PersonEmail FROM Case WHERE CaseNumber = :r.caseNumber.trim() LIMIT 1];
        if (cs.isEmpty()) { res.message = 'No case ' + r.caseNumber + ' found.'; return res; }
        Case c = cs[0];

        String resolution = String.isBlank(r.resolution) ? 'Resolved by the service agent.' : r.resolution.trim();
        String who = 'Chat Agent (' + UserInfo.getName() + ')';
        c.Status = 'Closed';
        c.Resolution__c = resolution;
        c.Resolved_By__c = who;
        update c;

        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = c.Account != null ? c.Account.PersonEmail : null; lr.agent = 'Service';
            lr.action = 'resolve_case'; lr.stage = 'Resolved';
            lr.result = 'Closed case ' + c.CaseNumber + ' by ' + who + ': ' + resolution;
            if (String.isNotBlank(lr.email)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.message = 'Case ' + c.CaseNumber + ' resolved and closed. Resolution: ' + resolution;
        return res;
    }
}
