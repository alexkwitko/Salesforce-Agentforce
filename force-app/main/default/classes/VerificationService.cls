/**
 * VerificationService — Tier-2 email OTP identity verification for the chat Service Agent.
 * The shopper proves control of the email on file by reading back a one-time code we email them.
 * Works WITHOUT a website login (so it unlocks login/password-issue cases). Codes are 6-digit,
 * 10-minute expiry, one-time, max 3 attempts, hashed at rest. A successful verify returns an
 * opaque proof token and stores only its hash; gated actions must pass that proof as verifiedEmail
 * for the next 30 minutes. A recent OTP row alone is never enough to unlock PII.
 * (Invocable wrappers live in RequestVerificationCodeAction / VerifyCodeAction — Apex allows only
 *  one @InvocableMethod per class.)
 */
public without sharing class VerificationService {

    private static final Integer EXPIRY_MIN  = 10;
    private static final Integer SESSION_MIN  = 30;
    private static final Integer RESEND_COOLDOWN_SECONDS = 120;
    private static final Integer MAX_ATTEMPTS = 3;
    private static final String  SALT = 'Kwitko::chatOTP::v1';
    private static final String  TOKEN_PREFIX = 'kwitko-otp-v1:';
    @TestVisible private static Boolean deliverInTests = false;
    @TestVisible private static Boolean forceEmailFailureInTests = false;
    @TestVisible private static String lastSalesforceSubject;

    public class Outcome { public Boolean ok; public String message; public String email; public String verifiedEmail; }

    /** Generate + email a one-time code. Never returns the code. */
    public static Outcome request(String emailIn, String conversationId) {
        return request(emailIn, conversationId, null);
    }

    /** Generate + email a one-time code. Never returns the code. */
    public static Outcome request(String emailIn, String conversationId, String chatSummary) {
        Outcome o = new Outcome(); o.ok = false;
        String email = (emailIn == null) ? '' : emailIn.trim();
        if (String.isBlank(email) || !email.contains('@')) { o.message = 'I need a valid email address to send your verification code.'; return o; }
        if (looksLikeThirdPartyRequest(chatSummary)) {
            o.message = 'For privacy, I can only send a verification code to the account owner in their own chat session. Please have the account owner contact us directly or sign in to their account.';
            return o;
        }
        purgeExpiredVerificationRowsBestEffort();
        String emailTargetId = resolveEmailTarget(email);
        if (emailTargetId == null) {
            o.message = 'I could not find a Kwitko account for that email. Please check the address or sign in to your account.';
            return o;
        }
        DateTime nowTime = System.now();

        List<Chat_Verification__c> pending = [
            SELECT Id, CreatedDate, Expires_At__c
            FROM Chat_Verification__c
            WHERE Email__c = :email
            AND Verified__c = false
            AND Expires_At__c > :nowTime
            AND (Attempts__c = null OR Attempts__c < :MAX_ATTEMPTS)
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];

        if (!pending.isEmpty()) {
            expireDuplicatePendingCodes(pending, nowTime);
            if (pending[0].CreatedDate != null
                && pending[0].CreatedDate >= nowTime.addSeconds(-RESEND_COOLDOWN_SECONDS)) {
                o.ok = true;
                o.email = email;
                o.message = 'I already emailed a 6-digit verification code to ' + mask(email)
                    + '. Please use the most recent code; it expires in ' + EXPIRY_MIN
                    + ' minutes. If it still does not arrive, wait a moment and ask me to resend it.';
                return o;
            }
        }

        String code = sixDigits();
        if (!Test.isRunningTest() || deliverInTests) {
            if (!deliverCode(email, code, emailTargetId)) {
                o.message = 'I could not send the verification code right now. Please try again or use the sign-in link.';
                return o;
            }
        }

        if (!pending.isEmpty()) {
            DateTime expiredAt = System.now().addSeconds(-1);
            for (Chat_Verification__c old : pending) old.Expires_At__c = expiredAt;
            update pending;
        }
        Chat_Verification__c verification = new Chat_Verification__c(
            Email__c = email, Code_Hash__c = hash(code), Expires_At__c = System.now().addMinutes(EXPIRY_MIN),
            Attempts__c = 0, Verified__c = false, Conversation_Id__c = conversationId);
        insert verification;
        o.ok = true;
        o.email = email;
        o.message = 'I have emailed a 6-digit verification code to ' + mask(email) + '. Please read it back to me (it expires in ' + EXPIRY_MIN + ' minutes).';
        return o;
    }

    private static void expireDuplicatePendingCodes(List<Chat_Verification__c> pending, DateTime nowTime) {
        if (pending == null || pending.size() <= 1) return;
        List<Chat_Verification__c> duplicates = new List<Chat_Verification__c>();
        DateTime expiredAt = nowTime.addSeconds(-1);
        for (Integer i = 1; i < pending.size(); i++) {
            pending[i].Expires_At__c = expiredAt;
            duplicates.add(pending[i]);
        }
        if (!duplicates.isEmpty()) update duplicates;
    }

    private static void purgeExpiredVerificationRowsBestEffort() {
        try {
            DateTime nowTs = System.now();
            List<Chat_Verification__c> expired = [
                SELECT Id
                FROM Chat_Verification__c
                WHERE Expires_At__c != null
                  AND Expires_At__c < :nowTs
                LIMIT 200
            ];
            if (expired.isEmpty()) return;

            Database.DeleteResult[] deletes = Database.delete(expired, false);
            List<SObject> deletedRows = new List<SObject>();
            for (Integer i = 0; i < deletes.size(); i++) {
                if (deletes[i].isSuccess()) deletedRows.add(expired[i]);
            }
            if (!deletedRows.isEmpty()) Database.emptyRecycleBin(deletedRows);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Expired OTP cleanup skipped: ' + e.getMessage());
        }
    }

    private static Boolean deliverCode(String email, String code, String emailTargetId) {
        if (deliverCodeWithSalesforce(email, code, emailTargetId)) {
            return true;
        }

        try {
            WooOrderActionService.WooResult woo = WooOrderActionService.sendVerificationCodeEmail(email, code, EXPIRY_MIN);
            if (woo != null && woo.success == true) return true;
            System.debug('Woo verification email did not send: ' + (woo == null ? 'no response' : woo.message));
            if (isExplicitWooMailFailure(woo)) return false;
        } catch (Exception e) {
            System.debug('Woo verification email failed: ' + e.getMessage());
        }

        return false;
    }

    private static Boolean isExplicitWooMailFailure(WooOrderActionService.WooResult woo) {
        if (woo == null || String.isBlank(woo.message)) return false;
        String message = woo.message.toLowerCase();
        return message.contains('mail_not_configured')
            || message.contains('fluentsmtp has no delivery connection configured')
            || message.contains('wordpress mailer failed');
    }

    private static Boolean deliverCodeWithSalesforce(String email, String code, String emailTargetId) {
        try {
            String subject = 'Your Kwitko Coffee verification code - ' + sixDigits();
            lastSalesforceSubject = subject;
            if (Test.isRunningTest()) return !forceEmailFailureInTests;
            EmailService.Request er = new EmailService.Request();
            er.toEmail = email;
            er.isTransactional = true;
            er.recordId = emailTargetId;
            er.subject = subject;
            er.htmlBody = '<p>Hi,</p><p>Your Kwitko Coffee verification code is:</p>'
                + '<p style="font-size:24px;font-weight:bold;letter-spacing:3px">' + code + '</p>'
                + '<p>It expires in ' + EXPIRY_MIN + ' minutes. If you did not request this, ignore this email.</p>';
            EmailService.Response sent = EmailService.send(new List<EmailService.Request>{ er })[0];
            return sent != null && sent.success == true;
        } catch (Exception e) {
            System.debug('Salesforce verification email failed: ' + e.getMessage());
            return false;
        }
    }

    private static Boolean looksLikeThirdPartyRequest(String chatSummary) {
        if (String.isBlank(chatSummary)) return false;
        String s = chatSummary.toLowerCase();
        List<String> blocked = new List<String>{
            'not mine',
            'not my account',
            'not my email',
            'not my order',
            'someone else',
            'someone else\'s',
            'somebody else',
            'somebody else\'s',
            'another person',
            'other person',
            'another account',
            'another order',
            'another email',
            'friend\'s account',
            'friend\'s order',
            'friend\'s email',
            'for my friend',
            'belongs to him',
            'belongs to her',
            'belongs to them'
        };
        for (String phrase : blocked) {
            if (s.contains(phrase)) return true;
        }
        return false;
    }

    private static String resolveEmailTarget(String email) {
        if (String.isBlank(email)) return null;
        String normalized = email.trim();

        List<Contact> contacts = [
            SELECT Id
            FROM Contact
            WHERE Email = :normalized
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!contacts.isEmpty()) return (String) contacts[0].Id;

        List<Account> personAccounts = [
            SELECT PersonContactId
            FROM Account
            WHERE IsPersonAccount = true
            AND PersonEmail = :normalized
            AND PersonContactId != null
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!personAccounts.isEmpty()) return (String) personAccounts[0].PersonContactId;

        List<Lead> leads = [
            SELECT Id
            FROM Lead
            WHERE Email = :normalized
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return leads.isEmpty() ? null : (String) leads[0].Id;
    }

    /** Check a code; on match, return an opaque proof for this verified email session. */
    public static Outcome verify(String emailIn, String codeIn) {
        Outcome o = new Outcome(); o.ok = false;
        String email = (emailIn == null) ? '' : emailIn.trim();
        o.email = email;
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
            String proof = newProofToken();
            cv.Verified__c = true;
            cv.Verified_Until__c = System.now().addMinutes(SESSION_MIN);
            cv.Verification_Token_Hash__c = hashToken(proof);
            update cv;
            o.ok = true; o.message = 'Thanks — you are verified. How can I help with your account?';
            o.verifiedEmail = proof;
        } else {
            cv.Attempts__c = (cv.Attempts__c == null ? 0 : cv.Attempts__c) + 1; update cv;
            Integer left = MAX_ATTEMPTS - cv.Attempts__c.intValue();
            o.message = left > 0 ? ('That code did not match. You have ' + left + ' attempt(s) left.') : 'That code did not match and attempts are used up — I will send a new code.';
        }
        return o;
    }

    /** Legacy diagnostic only. IdentityService does not use this as authorization by itself. */
    public static Boolean isSessionVerified(String email) {
        if (String.isBlank(email)) return false;
        String normalizedEmail = email.trim();
        return ![SELECT Id FROM Chat_Verification__c
                 WHERE Email__c = :normalizedEmail AND Verified__c = true AND Verified_Until__c > :System.now() LIMIT 1].isEmpty();
    }

    /** Used by IdentityService: does this opaque OTP proof match the requested email and time window? */
    public static Boolean isOtpProofVerified(String email, String proof) {
        if (String.isBlank(email) || String.isBlank(proof)) return false;
        String normalizedEmail = email.trim();
        String token = proof.trim();
        if (!token.startsWith(TOKEN_PREFIX)) return false;
        String tokenHash = hashToken(token);
        return ![SELECT Id FROM Chat_Verification__c
                 WHERE Email__c = :normalizedEmail
                 AND Verified__c = true
                 AND Verified_Until__c > :System.now()
                 AND Verification_Token_Hash__c = :tokenHash
                 LIMIT 1].isEmpty();
    }

    private static String sixDigits() {
        Integer n = Math.abs(Crypto.getRandomInteger());
        String s = String.valueOf(Math.mod(n, 1000000));
        while (s.length() < 6) s = '0' + s;
        return s;
    }
    @TestVisible private static String hash(String code) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(SALT + ':' + code)));
    }
    @TestVisible private static String hashToken(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(SALT + ':proof:' + token)));
    }
    private static String newProofToken() {
        String token = EncodingUtil.base64Encode(Crypto.generateAesKey(256))
            .replace('+', '-')
            .replace('/', '_')
            .replace('=', '');
        return TOKEN_PREFIX + token;
    }
    private static String mask(String email) {
        Integer at = email.indexOf('@');
        return at <= 1 ? email : email.substring(0,1) + '***' + email.substring(at);
    }
}
