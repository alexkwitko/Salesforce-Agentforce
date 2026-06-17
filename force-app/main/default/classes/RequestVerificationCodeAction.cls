/** Agent action: email a one-time verification code (Tier-2 identity). */
public without sharing class RequestVerificationCodeAction {
    public class Request {
        @InvocableVariable(label='Email' required=true description='Account email to send the one-time code to.') public String email;
        @InvocableVariable(label='Conversation Id') public String conversationId;
        @InvocableVariable(label='Chat Summary' description='Recent shopper wording around the verification request. Used only for safety screening.') public String chatSummary;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
        @InvocableVariable public String email;
    }
    @InvocableMethod(label='Request Verification Code'
        description='Emails a 6-digit one-time code to the shopper account email for identity verification. Returns success and a message to relay; never returns the code.')
    public static List<Result> run(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            VerificationService.Outcome o = VerificationService.request(r.email, r.conversationId, r.chatSummary);
            Result res = new Result();
            res.success = o.ok;
            res.message = o.message;
            res.email = r.email == null ? null : r.email.trim();
            out.add(res);
        }
        return out;
    }
}
