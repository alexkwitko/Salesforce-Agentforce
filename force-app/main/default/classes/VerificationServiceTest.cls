@isTest
private class VerificationServiceTest {
    private static String lastEndpoint;
    private static String lastBody;

    private class WooVerificationEmailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            lastEndpoint = req.getEndpoint();
            lastBody = req.getBody();
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(200);
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/wp-json/kwitko/v1/me')) {
                resp.setBody('{"logged_in":false,"bridge_version":"20260615.7"}');
            } else {
                resp.setBody('{"ok":true,"message":"sent"}');
            }
            return resp;
        }
    }

    private class StaleWooMailBridgeMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            lastEndpoint = req.getEndpoint();
            lastBody = req.getBody();
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(200);
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/wp-json/kwitko/v1/me')) {
                resp.setBody('{"logged_in":false,"bridge_version":"20260615.6"}');
            } else {
                resp.setBody('{"ok":true,"message":"sent"}');
            }
            return resp;
        }
    }

    private class WooMailNotConfiguredMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            lastEndpoint = req.getEndpoint();
            lastBody = req.getBody();
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/wp-json/kwitko/v1/me')) {
                resp.setStatusCode(200);
                resp.setBody('{"logged_in":false,"bridge_version":"20260615.7"}');
            } else {
                resp.setStatusCode(503);
                resp.setBody('{"code":"mail_not_configured","message":"FluentSMTP has no delivery connection configured.","data":{"status":503}}');
            }
            return resp;
        }
    }

    private static void seedEmailTarget(String email) {
        insert new Lead(LastName='OTP Target', Company='Kwitko Test', Email=email);
    }

    @isTest static void requestCodePath() {
        seedEmailTarget('shopper@example.com');
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'shopper@example.com';
        Test.startTest();
        RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
        Test.stopTest();
        System.assertEquals(true, r.success, 'request should succeed');
        System.assertEquals('shopper@example.com', r.email, 'action returns the email it sent to');
        System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='shopper@example.com']);
        // not verified until a correct code is entered
        System.assertEquals(false, IdentityService.isVerified('shopper@example.com', null));
    }

    @isTest static void requestCodeCoversEmailDeliveryBranch() {
        seedEmailTarget('delivery.branch@example.com');
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = false;
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'delivery.branch@example.com';
        try {
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            System.assertEquals(true, r.success, r.message);
            System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='delivery.branch@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
        }
    }

    @isTest static void requestCodeUsesSalesforceEmailBeforeWooMailer() {
        seedEmailTarget('sf.first@example.com');
        lastEndpoint = null;
        lastBody = null;
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = false;
        WooOrderActionService.allowHttpInTests = true;
        Test.setMock(HttpCalloutMock.class, new WooVerificationEmailMock());

        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'sf.first@example.com';

        try {
            Test.startTest();
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            Test.stopTest();

            System.assertEquals(true, r.success, r.message);
            System.assertEquals(null, lastEndpoint, 'Salesforce email should send first and skip Woo when it succeeds');
            System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='sf.first@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
            WooOrderActionService.allowHttpInTests = false;
        }
    }

    @isTest static void requestCodePurgesExpiredRowsBeforeCreatingNewCode() {
        insert new Chat_Verification__c(
            Email__c = 'cleanup.before.request@example.com',
            Code_Hash__c = 'old',
            Expires_At__c = System.now().addMinutes(-5),
            Verified__c = false,
            Attempts__c = 0
        );
        seedEmailTarget('cleanup.before.request@example.com');

        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'cleanup.before.request@example.com';
        RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];

        System.assertEquals(true, r.success, r.message);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'cleanup.before.request@example.com'
        ], 'the expired row should be purged before the fresh row is inserted');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'cleanup.before.request@example.com'
              AND Verified__c = false
              AND Expires_At__c > :System.now()
        ], 'only the fresh pending row should remain usable');
    }

    @isTest static void requestCodeFallsBackToWooWhenSalesforceEmailFails() {
        seedEmailTarget('woo.fallback@example.com');
        lastEndpoint = null;
        lastBody = null;
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = true;
        WooOrderActionService.allowHttpInTests = true;
        Test.setMock(HttpCalloutMock.class, new WooVerificationEmailMock());

        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'woo.fallback@example.com';

        try {
            Test.startTest();
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            Test.stopTest();

            System.assertEquals(true, r.success, r.message);
            System.assert(lastEndpoint != null && lastEndpoint.endsWith('/wp-json/kwitko/v1/verification-code-email'),
                'Woo bridge should be used only after Salesforce email fails');
            System.assert(lastBody != null && lastBody.contains('woo.fallback@example.com'), lastBody);
            System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='woo.fallback@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
            WooOrderActionService.allowHttpInTests = false;
        }
    }

    @isTest static void requestCodeStillFailsWhenBothMailersFail() {
        seedEmailTarget('no.mail@example.com');
        lastEndpoint = null;
        lastBody = null;
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = true;
        WooOrderActionService.allowHttpInTests = true;
        Test.setMock(HttpCalloutMock.class, new WooMailNotConfiguredMock());

        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'no.mail@example.com';

        try {
            Test.startTest();
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            Test.stopTest();

            System.assertEquals(false, r.success, 'both mailers failing must not create an OTP row');
            System.assert(r.message.contains('could not send'), r.message);
            System.assertEquals(0, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='no.mail@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
            WooOrderActionService.allowHttpInTests = false;
        }
    }

    @isTest static void requestCodeReusesVeryRecentPendingCodeWithoutSendingAgain() {
        seedEmailTarget('resend@example.com');
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'resend@example.com';

        RequestVerificationCodeAction.Result first = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
        RequestVerificationCodeAction.Result second = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];

        System.assertEquals(true, first.success, first.message);
        System.assertEquals(true, second.success, second.message);
        System.assert(second.message.contains('already emailed'), second.message);
        System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='resend@example.com'],
            'rapid duplicate requests reuse the active code instead of spraying more emails');
    }

    @isTest static void requestCodeResendsAfterCooldownAndExpiresOlderPendingCode() {
        seedEmailTarget('resend.after.cooldown@example.com');
        VerificationService.deliverInTests = true;
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'resend.after.cooldown@example.com';

        try {
            RequestVerificationCodeAction.Result first = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            String firstSubject = VerificationService.lastSalesforceSubject;
            Chat_Verification__c existing = [
                SELECT Id
                FROM Chat_Verification__c
                WHERE Email__c = 'resend.after.cooldown@example.com'
                LIMIT 1
            ];
            Test.setCreatedDate(existing.Id, System.now().addMinutes(-3));

            RequestVerificationCodeAction.Result second = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            String secondSubject = VerificationService.lastSalesforceSubject;

            System.assertEquals(true, first.success, first.message);
            System.assertEquals(true, second.success, second.message);
            System.assertEquals(2, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='resend.after.cooldown@example.com'],
                'after the cooldown, a new audit row and fresh code are created');
            System.assertNotEquals(firstSubject, secondSubject, 'fresh sends use unique subjects so Gmail does not thread into a trashed OTP conversation');
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
        }
        DateTime nowTime = System.now();
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'resend.after.cooldown@example.com'
              AND Verified__c = false
              AND Expires_At__c > :nowTime
        ], 'only the newest code remains usable');
    }

    @isTest static void requestCodeUsesFallbackMailerInTestContext() {
        seedEmailTarget('fallback@example.com');
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = true;
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'fallback@example.com';
        try {
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            System.assertEquals(true, r.success, r.message);
            System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='fallback@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
        }
    }

    @isTest static void unknownEmailDoesNotReachMailFallback() {
        VerificationService.deliverInTests = true;
        VerificationService.forceEmailFailureInTests = true;
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'stale.bridge@example.com';
        try {
            RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
            System.assertEquals(false, r.success, 'unknown emails must not create OTP rows');
            System.assert(r.message.contains('could not find'), r.message);
            System.assertEquals(0, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='stale.bridge@example.com']);
        } finally {
            VerificationService.deliverInTests = false;
            VerificationService.forceEmailFailureInTests = false;
        }
    }

    @isTest static void wrongAndExpiredCodes() {
        insert new Chat_Verification__c(Email__c='exp@example.com', Code_Hash__c='deadbeef',
            Expires_At__c=System.now().addMinutes(-1), Verified__c=false, Attempts__c=0);
        VerifyCodeAction.Request vr = new VerifyCodeAction.Request(); vr.email='exp@example.com'; vr.code='123456';
        System.assertEquals(false, VerifyCodeAction.run(new List<VerifyCodeAction.Request>{vr})[0].verified, 'expired rejected');

        insert new Chat_Verification__c(Email__c='live@example.com', Code_Hash__c='nomatch',
            Expires_At__c=System.now().addMinutes(5), Verified__c=false, Attempts__c=0);
        VerifyCodeAction.Request vr2 = new VerifyCodeAction.Request(); vr2.email='live@example.com'; vr2.code='999999';
        System.assertEquals(false, VerifyCodeAction.run(new List<VerifyCodeAction.Request>{vr2})[0].verified, 'wrong code rejected');
    }

    @isTest static void otpProofGatesIdentity() {
        String proof = 'kwitko-otp-v1:test-proof-token';
        insert new Chat_Verification__c(Email__c='vip@example.com', Code_Hash__c='x',
            Expires_At__c=System.now().addMinutes(5), Verified__c=true,
            Verified_Until__c=System.now().addMinutes(20), Attempts__c=0,
            Verification_Token_Hash__c=VerificationService.hashToken(proof));
        System.assertEquals(true, VerificationService.isSessionVerified('vip@example.com'));
        System.assertEquals(false, IdentityService.isVerified('vip@example.com', null), 'recent OTP row alone is not enough');
        System.assertEquals(false, IdentityService.isVerified('VIP@example.com', ''), 'blank proof is not enough');
        System.assertEquals(true, IdentityService.isVerified('VIP@example.com', proof), 'opaque OTP proof verifies case-insensitively');
        System.assertEquals(false, IdentityService.isVerified('other@example.com', proof), 'proof is scoped to the requested email');
        insert new Chat_Verification__c(Email__c='old@example.com', Code_Hash__c='x',
            Expires_At__c=System.now().addMinutes(-30), Verified__c=true,
            Verified_Until__c=System.now().addMinutes(-1), Attempts__c=0,
            Verification_Token_Hash__c=VerificationService.hashToken('kwitko-otp-v1:old-proof'));
        System.assertEquals(false, VerificationService.isSessionVerified('old@example.com'), 'expired window');
        System.assertEquals(false, IdentityService.isVerified('old@example.com', 'kwitko-otp-v1:old-proof'), 'expired proof rejected');
    }

    @isTest static void verifyCodeReturnsOpaqueProof() {
        insert new Chat_Verification__c(Email__c='proof@example.com',
            Code_Hash__c=VerificationService.hash('123456'),
            Expires_At__c=System.now().addMinutes(5), Verified__c=false, Attempts__c=0);

        VerifyCodeAction.Request vr = new VerifyCodeAction.Request();
        vr.email = 'proof@example.com';
        vr.code = '123456';
        VerifyCodeAction.Result res = VerifyCodeAction.run(new List<VerifyCodeAction.Request>{vr})[0];

        System.assertEquals(true, res.verified, res.message);
        System.assertEquals('proof@example.com', res.email);
        System.assert(res.verifiedEmail != null && res.verifiedEmail.startsWith('kwitko-otp-v1:'), 'returns opaque proof');
        System.assertEquals(true, IdentityService.isVerified('proof@example.com', res.verifiedEmail), 'proof unlocks requested email');
    }

    @isTest static void tier1StillWorks() {
        System.assertEquals(true,  IdentityService.isVerified('a@b.com', 'a@b.com'));
        System.assertEquals(false, IdentityService.isVerified('a@b.com', 'c@d.com'));
        System.assertEquals(false, IdentityService.isVerified(null, 'a@b.com'));
        System.assert(String.isNotBlank(IdentityService.signInMessage()), 'sign-in message present');
        System.assert(IdentityService.signInMessage().contains(IdentityService.LOGIN_URL));
    }

    @isTest static void badInputs() {
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request(); rq.email='notanemail';
        System.assertEquals(false, RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0].success);
        VerifyCodeAction.Request vr = new VerifyCodeAction.Request(); vr.email=''; vr.code='';
        System.assertEquals(false, VerifyCodeAction.run(new List<VerifyCodeAction.Request>{vr})[0].verified);
    }

    @isTest static void refusesUnknownAndThirdPartyOtpRequests() {
        RequestVerificationCodeAction.Request unknown = new RequestVerificationCodeAction.Request();
        unknown.email = 'unknown@example.com';
        RequestVerificationCodeAction.Result unknownResult = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{unknown})[0];
        System.assertEquals(false, unknownResult.success, unknownResult.message);
        System.assertEquals(0, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='unknown@example.com']);

        seedEmailTarget('known.other@example.com');
        RequestVerificationCodeAction.Request thirdParty = new RequestVerificationCodeAction.Request();
        thirdParty.email = 'known.other@example.com';
        thirdParty.chatSummary = 'Shopper said this is someone else and not mine.';
        RequestVerificationCodeAction.Result thirdPartyResult = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{thirdParty})[0];
        System.assertEquals(false, thirdPartyResult.success, thirdPartyResult.message);
        System.assert(thirdPartyResult.message.contains('account owner'), thirdPartyResult.message);
        System.assertEquals(0, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='known.other@example.com']);
    }

    @isTest static void allowsOwnerOtpWhenAgentSummaryUsesTheirEmail() {
        seedEmailTarget('owner.summary@example.com');

        RequestVerificationCodeAction.Request owner = new RequestVerificationCodeAction.Request();
        owner.email = 'owner.summary@example.com';
        owner.chatSummary = 'Shopper provided their account email and asked for a verification code for their order.';

        RequestVerificationCodeAction.Result result = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{owner})[0];

        System.assertEquals(true, result.success, result.message);
        System.assertEquals('owner.summary@example.com', result.email);
        System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='owner.summary@example.com']);
    }
}
