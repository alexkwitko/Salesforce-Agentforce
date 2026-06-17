/** PasswordResetService (password_reset_link) — returns the secure WordPress password-reset link. Never sets
 *  passwords. No PII returned, so it does not require verification (anyone can request a reset link). */
public without sharing class PasswordResetService {
    private static final String RESET='https://deepskyblue-deer-920559.hostingersite.com/my-account-2/lost-password/';
    public class Request {
        @InvocableVariable(label='Email') public String email;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the password reset request so the solved service Case has context.')
        public String chatSummary;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String resetUrl;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public String message;
    }
    @InvocableMethod(label='Password Reset Link' description='Returns the secure password-reset link for the storefront. Never sets or reveals passwords.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs){ Result res=new Result(); res.success=true; res.resetUrl=RESET;
        res.message='You can reset your password securely here: '+RESET+' — for your safety I cannot set or view passwords myself.';
        res.caseNumber=createSolvedCase(r, res.message);
        o.add(res);} return o; }

    private static String createSolvedCase(Request r, String resolution){
        try{
            Account acc=null;
            if(r!=null && String.isNotBlank(r.email)) acc=KwitkoServiceUtil.findAccount(r.email);
            Id caseId=CaseTranscriptUtil.insertSolvedCase(
                acc==null?null:acc.Id,
                acc==null?null:acc.PersonContactId,
                r==null?null:r.email,
                null,
                null,
                'Account',
                'Chat service: Password reset link provided',
                resolution,
                r==null?null:r.chatSummary
            );
            if(caseId==null) return null;
            List<Case> cases=[SELECT CaseNumber FROM Case WHERE Id=:caseId LIMIT 1];
            return cases.isEmpty()?null:cases[0].CaseNumber;
        }catch(Exception e){
            System.debug('password reset case creation failed: '+e.getMessage());
            return null;
        }
    }
}
