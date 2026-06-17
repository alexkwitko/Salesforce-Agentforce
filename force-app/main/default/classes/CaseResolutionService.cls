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
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the conversation that led to this resolution.')
        public String chatSummary;
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
        List<Case> cs = [
            SELECT Id, Status, CaseNumber, AccountId, Account.PersonEmail, ContactId, Description
            FROM Case
            WHERE CaseNumber = :r.caseNumber.trim()
            LIMIT 1
        ];
        if (cs.isEmpty()) { res.message = 'No case ' + r.caseNumber + ' found.'; return res; }
        Case c = cs[0];

        String resolution = String.isBlank(r.resolution) ? 'Resolved by the service agent.' : r.resolution.trim();
        String who = 'Chat Agent (' + UserInfo.getName() + ')';
        String transcript = String.isBlank(r.chatSummary)
            ? 'Transcript not provided by agent action.'
            : CaseTranscriptUtil.sanitizePreActionCaseClaims(r.chatSummary);
        String detail = '--- Resolution details ---\nResolved by: ' + who + '\nResolved at: '
            + System.now().format() + '\nResolution: ' + resolution
            + '\n\n--- Chat transcript ---\n' + transcript;
        c.Status = 'Closed';
        c.Resolution__c = truncate(resolution, 4000);
        c.Resolved_By__c = who;
        c.Description = appendBlock(c.Description, detail);
        update c;
        CaseTranscriptUtil.insertTaskWithResolution(c.Id, c.ContactId, resolution, transcript);

        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = c.Account != null ? c.Account.PersonEmail : null; lr.agent = 'Service';
            lr.action = 'resolve_case'; lr.stage = 'Resolved';
            lr.result = 'Closed case ' + c.CaseNumber + ' by ' + who + ': ' + resolution;
            lr.chatSummary = r.chatSummary;
            if (String.isNotBlank(lr.email)) JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        if (c.AccountId != null) {
            DataCloudAugmentationService.refreshAccount(c.AccountId);
            DataCloudAugmentationService.refreshAccountFromDataCloudAsync(c.AccountId);
        }

        res.success = true;
        res.message = 'Case ' + c.CaseNumber + ' resolved and closed. Resolution: ' + resolution;
        return res;
    }

    private static String appendBlock(String existing, String block) {
        String combined = (String.isBlank(existing) ? '' : existing.trim() + '\n\n') + block;
        return truncate(combined, 32000);
    }

    private static String truncate(String value, Integer maxLen) {
        if (value == null || maxLen == null || maxLen <= 0) return value;
        return value.length() > maxLen ? value.substring(0, maxLen) : value;
    }
}
