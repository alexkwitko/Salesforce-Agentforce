/**
 * WebIdentityService — links a browser's Data Cloud Web SDK deviceId to a VERIFIED email, even when
 * the shopper never logged into WordPress (e.g. they identified themselves in the chat).
 *
 * Flow (reuse-the-SDK design):
 *   agent verifies email (Tier-1 loggedInEmail OR Tier-2 email OTP)
 *     -> calls this action with the browser cartToken (hidden pre-chat var) + the verified email
 *     -> POSTs {token,email} to /wp-json/kwitko/v1/identify (HMAC-signed, same secret as the cart queue)
 *     -> the storefront controller polls that endpoint, and on a hit calls the native
 *        kwitkoIdentify(email) -> the Web SDK sends its own deviceId<->email identity event
 *     -> Data Cloud Identity Resolution (email rule) unifies that device's activity to the person.
 *
 * Mirrors CartQueueService (Named Credential WooCommerce + KWITKO_WHK_SECRET HMAC). Gated: only ever
 * called by the agent AFTER IdentityService.isVerified, so we never link a device to an unverified claim.
 */
public without sharing class WebIdentityService {

    // Must match KWITKO_WHK_SECRET in wp-config (same secret the storefront verifies for the cart queue).

    public class Request {
        @InvocableVariable(label='Cart Token' description='Browser cart token from hidden pre-chat (Kwitko_Cart_Token__c).' required=true)
        public String cartToken;
        @InvocableVariable(label='Email' description='The raw shopper email to link to this browser device. Required when verifiedEmail is an OTP proof.')
        public String email;
        @InvocableVariable(label='Verified Email' description='Signed-in loggedInEmail, or the opaque OTP proof returned by verify_code. Never a typed/unverified claim.' required=true)
        public String verifiedEmail;
        @InvocableVariable(label='First Name') public String firstName;
    }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Link Web Identity to Email'
        description='Links the browser deviceId (via cart token) to the VERIFIED email so anonymous web activity unifies to the shopper. Call only after the email is verified.')
    public static List<Result> link(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(doLink(r));
        return out;
    }

    private static Result doLink(Request r) {
        Result res = new Result(); res.success = false;
        if (r == null || String.isBlank(r.cartToken) || String.isBlank(r.verifiedEmail)) {
            res.message = 'cartToken and verifiedEmail are required.'; return res;
        }
        String email = String.isBlank(r.email) ? r.verifiedEmail : r.email;
        if (!IdentityService.isVerified(email, r.verifiedEmail)) {
            res.message = IdentityService.signInMessage(); return res;
        }
        Map<String, Object> body = new Map<String, Object>{
            'token' => r.cartToken,
            'email' => email.trim().toLowerCase(),
            'firstName' => (r.firstName == null ? '' : r.firstName) };
        String raw = JSON.serialize(body);
        try {
            Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf(KwitkoSecrets.whk()));
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WooCommerce/wp-json/kwitko/v1/identify');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('X-Kwitko-Signature', EncodingUtil.base64Encode(mac));
            req.setBody(raw);
            req.setTimeout(60000);
            HttpResponse resp = new Http().send(req);
            res.success = resp.getStatusCode() >= 200 && resp.getStatusCode() < 300;
            res.message = res.success ? 'Device identity queued for stitch.' : ('Identify failed: ' + resp.getStatusCode());
        } catch (Exception e) {
            res.message = 'Identify exception: ' + e.getMessage();
        }
        return res;
    }
}
