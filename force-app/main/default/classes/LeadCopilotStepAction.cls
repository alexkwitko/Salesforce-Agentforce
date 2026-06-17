/**
 * LeadCopilotStepAction — agent/Flow-invocable wrapper for the profile-driven nurture step.
 * Returns the recommended next-best-action so the agent can present it.
 */
public with sharing class LeadCopilotStepAction {
    public class Request {
        @InvocableVariable(label='Lead ID' required=true) public Id leadId;
    }
    public class Result {
        @InvocableVariable public String nextBestAction;
        @InvocableVariable public Boolean emailSent;
        @InvocableVariable public String message;
        @InvocableVariable public Boolean success;
    }
    @InvocableMethod(label='Run Lead Nurture Step'
        description='Derive the next-best-action from the lead profile, record it, and send the personalized nurture email.')
    public static List<Result> run(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            LeadCopilotService.StepResult s = LeadCopilotService.runNurtureStep(r.leadId);
            Result res = new Result();
            res.nextBestAction = s.nextBestAction;
            res.emailSent = s.emailSent;
            res.message = s.message;
            res.success = s.success;
            out.add(res);
        }
        return out;
    }
}
