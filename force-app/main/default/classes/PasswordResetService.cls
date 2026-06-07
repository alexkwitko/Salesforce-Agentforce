/** PasswordResetService (password_reset_link) — returns the secure WordPress password-reset link. Never sets
 *  passwords. No PII returned, so it does not require verification (anyone can request a reset link). */
public without sharing class PasswordResetService {
    private static final String RESET='https://deepskyblue-deer-920559.hostingersite.com/my-account-2/lost-password/';
    public class Request { @InvocableVariable(label='Email') public String email; }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String resetUrl; @InvocableVariable public String message; }
    @InvocableMethod(label='Password Reset Link' description='Returns the secure password-reset link for the storefront. Never sets or reveals passwords.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs){ Result res=new Result(); res.success=true; res.resetUrl=RESET;
        res.message='You can reset your password securely here: '+RESET+' — for your safety I cannot set or view passwords myself.'; o.add(res);} return o; }
}
