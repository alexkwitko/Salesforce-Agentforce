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

    /** Verified iff a non-blank verifiedEmail matches the requested email (case-insensitive). */
    public static Boolean isVerified(String requestedEmail, String verifiedEmail) {
        if (String.isBlank(requestedEmail) || String.isBlank(verifiedEmail)) return false;
        return requestedEmail.trim().equalsIgnoreCase(verifiedEmail.trim());
    }

    /** Friendly "please sign in" message with the secure account link — returned instead of any PII. */
    public static String signInMessage() {
        return 'For your security I can only share order, account, or coupon details once you\'re signed in. '
            + 'Use the Sign in to your account button in this chat and I\'ll have everything ready: ' + LOGIN_URL;
    }
}
