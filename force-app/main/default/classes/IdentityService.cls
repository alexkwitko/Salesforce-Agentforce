/**
 * IdentityService — server-side identity gate for PII.
 * An email typed into chat is NOT proof of identity. PII (order history, status, coupons, saved cart,
 * address, lifetime value, cases) may be returned ONLY for a VERIFIED identity: the JWT-verified
 * messaging end-user email (passed by the agent as `verifiedEmail`, sourced from the loggedInEmail
 * context variable that is populated only after a real verified sign-in). Fail-closed: no verified
 * signal => not verified => no PII. This closes the impersonation hole regardless of the agent prompt.
 */
public without sharing class IdentityService {

    public static final String LOGIN_URL = 'https://deepskyblue-deer-920559.hostingersite.com/?kwitko_login=1';

    /**
     * Verified iff EITHER:
     *  - Tier-1: a non-blank verifiedEmail (the signed-in loggedInEmail) matches the requested email, OR
     *  - Tier-2: verifiedEmail is the opaque OTP proof returned by VerifyCodeAction for this email.
     * Tier-2 is what lets a shopper who CANNOT log in (password/login issues) still prove identity.
     */
    public static Boolean isVerified(String requestedEmail, String verifiedEmail) {
        if (String.isBlank(requestedEmail)) return false;
        String req = requestedEmail.trim();
        if (String.isBlank(verifiedEmail)) return false;
        String verified = verifiedEmail.trim();
        if (VerificationService.isOtpProofVerified(req, verified)) return true; // Tier-2 email OTP proof
        return req.equalsIgnoreCase(verified); // Tier-1 logged-in email
    }

    /**
     * Returned by gated actions when the shopper is not yet verified. Leads with the EMAIL OTP path
     * (works even if they can't log in) so the agent verifies by code first; sign-in link is the
     * secondary option. The agent should call request_verification_code → verify_code, not just paste a link.
     */
    public static String signInMessage() {
        return 'To protect your account I need to verify it\'s you first. The quickest way: I\'ll email a 6-digit '
            + 'verification code to your account email and you read it back to me — this works even if you can\'t log in. '
            + 'Want me to send the code? (If you\'d rather sign in instead, you can: ' + LOGIN_URL + ')';
    }
}
