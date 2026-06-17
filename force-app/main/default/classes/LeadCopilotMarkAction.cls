/**
 * LeadCopilotMarkAction — agent/Flow-invocable wrapper to hand a lead off to the Nurture track.
 * Used by the Inside Sales agent (and any Flow) when conversion isn't possible now.
 */
public with sharing class LeadCopilotMarkAction {
    public class Request {
        @InvocableVariable(label='Lead ID' required=true) public Id leadId;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }
    @InvocableMethod(label='Mark Lead For Nurture'
        description='Move a lead to Nurture status and stamp the nurture start date. Use when conversion is not possible now.')
    public static List<Result> run(List<Request> reqs) {
        Set<Id> ids = new Set<Id>();
        for (Request r : reqs) if (r.leadId != null) ids.add(r.leadId);
        Integer moved = LeadCopilotService.markNurture(ids);
        List<Result> out = new List<Result>();
        for (Integer i = 0; i < reqs.size(); i++) {
            Result res = new Result();
            res.success = true;
            res.message = moved + ' lead(s) moved to Nurture.';
            out.add(res);
        }
        return out;
    }
}
