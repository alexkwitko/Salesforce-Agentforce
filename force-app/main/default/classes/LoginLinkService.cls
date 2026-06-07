/**
 * LoginLinkService — returns a "Sign in to your account" link the concierge can present in chat as a
 * Rich Link (Adaptive Response Formats) when an UNVERIFIED shopper asks for account internals
 * (orders, address, lifetime value). The shopper taps it → the storefront opens the real WooCommerce login (the
 * password is entered on the real site, never in the chat). Field names match the Rich Link adaptive
 * response contract (linkTitle/linkUrl/linkImageUrl/description) so the channel can render a card.
 */
public without sharing class LoginLinkService {

    private static final String STORE = 'https://deepskyblue-deer-920559.hostingersite.com';

    public class Request {
        @InvocableVariable(label='Reason (optional)') public String reason;
    }
    public class Result {
        @InvocableVariable public String linkTitle;       // button/card label
        @InvocableVariable public String linkUrl;         // destination = real site login
        @InvocableVariable public String linkImageUrl;    // optional card image
        @InvocableVariable public String description;     // text shown before the link
        @InvocableVariable public Boolean success;
    }

    @InvocableMethod(label='Get Sign-In Link'
        description='Returns a Rich Link to the storefront login page. Present this to an UNVERIFIED shopper who asks for account details; do NOT reveal personal data (orders, address, lifetime value) until they sign in.')
    public static List<Result> getSignInLink(List<Request> reqs) {
        Result r = new Result();
        r.linkTitle = 'Sign in to your account';
        r.linkUrl = STORE + '/?kwitko_login=1';
        r.linkImageUrl = STORE + '/wp-content/uploads/kwitko-logo.png';
        r.description = 'To protect your privacy, please sign in to view your account details.';
        r.success = true;
        return new List<Result>{ r };
    }
}
