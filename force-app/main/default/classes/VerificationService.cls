/**
 * VerificationService — Tier-2 email OTP identity verification for the chat Service Agent.
 * The shopper proves control of the email on file by reading back a one-time code we email them.
 * Works WITHOUT a website login (so it unlocks login/password-issue cases). Codes are 6-digit,
 * 10-minute expiry, one-time, max 3 attempts, hashed at rest. A successful verify marks the email
 * session-verified for 30 minutes; IdentityService.isVerified then treats that email as verified.
 * (Invocable wrappers live in RequestVerificationCodeAction / VerifyCodeAction — Apex allows only
 *  one @InvocableMethod per class.)
 */
public without sharing class VerificationService {

    private static final Integer EXPIRY_MIN  = 10;
    private static final Integer SESSION_MIN  = 30;
    private static final Integer MAX_ATTEMPTS = 3;
    private static final String  SALT = 'Kwitko::chatOTP::v1';

    public class Outcome { public Boolean ok; public String message; }

    /** Generate + email a one-time code. Never returns the code. */
    public static Outcome request(String emailIn, String conversationId) {
        Outcome o = new Outcome(); o.ok = false;
        String email = (emailIn == null) ? '' : emailIn.trim();
        if (String.isBlank(email) || !email.contains('@')) { o.message = 'I need a valid email address to send your verification code.'; return o; }
        String code = sixDigits();
        insert new Chat_Verification__c(
            Email__c = email, Code_Hash__c = hash(code), Expires_At__c = System.now().addMinutes(EXPIRY_MIN),
            Attempts__c = 0, Verified__c = false, Conversation_Id__c = conversationId);
        if (!Test.isRunningTest()) {
            EmailService.Request er = new EmailService.Request();
            er.toEmail = email; er.isTransactional = true;
            er.subject = 'Your Kwitko Coffee verification code';
            er.htmlBody = '<p>Hi,</p><p>Your Kwitko Coffee verification code is:</p>'
                + '<p style="font-size:24px;font-weight:bold;letter-spacing:3px">' + code + '</p>'
                + '<p>It expires in ' + EXPIRY_MIN + ' minutes. If you did not request this, ignore this email.</p>';
            try { EmailService.send(new List<EmailService.Request>{ er }); } catch (Exception e) { /* agent can offer resend */ }
        }
        o.ok = true;
        o.message = 'I have emailed a 6-digit verification code to ' + mask(email) + '. Please read it back to me (it expires in ' + EXPIRY_MIN + ' minutes).';
        return o;
    }

    /** Check a code; on match, mark the email session-verified. */
    public static Outcome verify(String emailIn, String codeIn) {
        Outcome o = new Outcome(); o.ok = false;
        String email = (emailIn == null) ? '' : emailIn.trim();
        String code  = (codeIn == null) ? '' : codeIn.trim().replaceAll('[^0-9]', '');
        if (String.isBlank(email) || String.isBlank(code)) { o.message = 'I need both your email and the code to verify.'; return o; }
        List<Chat_Verification__c> rows = [
            SELECT Id, Code_Hash__c, Expires_At__c, Attempts__c FROM Chat_Verification__c
            WHERE Email__c = :email AND Verified__c = false ORDER BY CreatedDate DESC LIMIT 1];
        if (rows.isEmpty()) { o.message = 'I do not have a pending code for ' + mask(email) + '. Want me to send a new one?'; return o; }
        Chat_Verification__c cv = rows[0];
        if (cv.Expires_At__c < System.now()) { o.message = 'That code has expired. I can send you a fresh one.'; return o; }
        if (cv.Attempts__c != null && cv.Attempts__c >= MAX_ATTEMPTS) { o.message = 'Too many attempts on that code. I will send a new one and we can try again.'; return o; }
        if (cv.Code_Hash__c == hash(code)) {
            cv.Verified__c = true; cv.Verified_Until__c = System.now().addMinutes(SESSION_MIN); update cv;
            o.ok = true; o.message = 'Thanks — you are verified. How can I help with your account?';
        } else {
            cv.Attempts__c = (cv.Attempts__c == null ? 0 : cv.Attempts__c) + 1; update cv;
            Integer left = MAX_ATTEMPTS - cv.Attempts__c.intValue();
            o.message = left > 0 ? ('That code did not match. You have ' + left + ' attempt(s) left.') : 'That code did not match and attempts are used up — I will send a new code.';
        }
        return o;
    }

    /** Used by IdentityService: is this email currently session-verified by a recent OTP? */
    public static Boolean isSessionVerified(String email) {
        if (String.isBlank(email)) return false;
        return ![SELECT Id FROM Chat_Verification__c
                 WHERE Email__c = :email.trim() AND Verified__c = true AND Verified_Until__c > :System.now() LIMIT 1].isEmpty();
    }

    private static String sixDigits() {
        Integer n = Math.abs(Crypto.getRandomInteger());
        String s = String.valueOf(Math.mod(n, 1000000));
        while (s.length() < 6) s = '0' + s;
        return s;
    }
    private static String hash(String code) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(SALT + ':' + code)));
    }
    private static String mask(String email) {
        Integer at = email.indexOf('@');
        return at <= 1 ? email : email.substring(0,1) + '***' + email.substring(at);
    }
}
