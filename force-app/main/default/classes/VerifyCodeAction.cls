/** Agent action: verify the one-time code the shopper provided (Tier-2 identity). */
public without sharing class VerifyCodeAction {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Code' required=true description='The 6-digit code the shopper typed.') public String code;
    }
    public class Result {
        @InvocableVariable public Boolean verified;
        @InvocableVariable public String message;
        @InvocableVariable(label='Email') public String email;
        @InvocableVariable(label='Verified Email Proof' description='Opaque proof to pass as verifiedEmail to gated service actions after verified=true. Do not show to the shopper.')
        public String verifiedEmail;
    }
    @InvocableMethod(label='Verify Code'
        description='Checks the one-time code the shopper provided. On match, returns an opaque proof to pass as verifiedEmail to gated account actions. Returns verified true/false and a message.')
    public static List<Result> run(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            VerificationService.Outcome o = VerificationService.verify(r.email, r.code);
            Result res = new Result();
            res.verified = o.ok;
            res.message = o.message;
            res.email = o.email;
            res.verifiedEmail = o.verifiedEmail;
            out.add(res);
        }
        return out;
    }
}
