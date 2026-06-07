/**
 * WinbackService — confidence-rebuild offer after a return. Builds a recommendation (which now
 * automatically EXCLUDES the product the customer returned), issues a generous single-use coupon,
 * and sends a consent-gated apology email. Clears Winback_Needed__c so it fires once per return.
 */
public without sharing class WinbackService {

    private static final Integer WINBACK_PCT = 20; // generous — rebuild trust after a return

    public static void sendWinback(Id accountId) {
        if (accountId == null) return;
        List<Account> accs = [SELECT Id, FirstName, PersonEmail, Email_Consent__c, Last_Return_Reason__c,
                                     Winback_Needed__c
                              FROM Account WHERE Id = :accountId LIMIT 1];
        if (accs.isEmpty()) return;
        Account a = accs[0];
        try {
            if (String.isBlank(a.PersonEmail)) return;

            // A product to feature — engine excludes the returned item automatically.
            String featured = null;
            try {
                RecommendationStrategyService.Request rq = new RecommendationStrategyService.Request();
                rq.email = a.PersonEmail; rq.channel = 'post_purchase';
                RecommendationStrategyService.Result rec =
                    RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ rq })[0];
                featured = rec != null ? rec.primaryProductName : null;
            } catch (Exception e) { /* recommendation optional */ }

            // Generous, single-use, email-restricted coupon.
            String first = String.isBlank(a.FirstName) ? 'FRIEND' : a.FirstName.toUpperCase().replaceAll('[^A-Z0-9]', '');
            if (String.isBlank(first)) first = 'FRIEND';
            String code = 'KW-BACK-' + WINBACK_PCT + '-' + first.left(6);
            if (!Test.isRunningTest()) {
                WooCouponService.createPercentCoupon(code, WINBACK_PCT, Date.today().addDays(30), a.PersonEmail, null);
            }

            // Apology + offer email (consent-gated via recordId = the account).
            EmailService.Request er = new EmailService.Request();
            er.toEmail = a.PersonEmail;
            er.subject = 'We want to make it right — ' + WINBACK_PCT + '% off your next Kwitko order';
            er.htmlBody = '<p>Hi ' + (String.isBlank(a.FirstName) ? 'there' : a.FirstName) + ',</p>'
                + '<p>We\'re sorry your recent order didn\'t work out, and your refund is on its way. '
                + 'We\'d love the chance to win you back.</p>'
                + '<p>Here\'s <strong>' + WINBACK_PCT + '% off</strong> your next order with code <strong>' + code + '</strong>'
                + (String.isBlank(featured) ? '' : (' — may we suggest <strong>' + featured + '</strong>')) + '.</p>'
                + '<p>Thank you for giving us another shot.<br/>— Kwitko Coffee Co.</p>';
            er.recordId = a.Id;
            EmailService.send(new List<EmailService.Request>{ er });
        } catch (Exception e) {
            System.debug('Winback error: ' + e.getMessage());
        } finally {
            // Fire once per return regardless of email outcome (fresh sObject avoids PA Name write).
            if (a.Winback_Needed__c == true) update new Account(Id = a.Id, Winback_Needed__c = false);
        }
    }
}
