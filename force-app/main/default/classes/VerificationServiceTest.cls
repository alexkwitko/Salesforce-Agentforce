@isTest
private class VerificationServiceTest {

    @isTest static void requestCodePath() {
        RequestVerificationCodeAction.Request rq = new RequestVerificationCodeAction.Request();
        rq.email = 'shopper@example.com';
        Test.startTest();
        RequestVerificationCodeAction.Result r = RequestVerificationCodeAction.run(new List<RequestVerificationCodeAction.Request>{rq})[0];
        Test.stopTest();
        System.assertEquals(true, r.success, 'request should succeed');
        System.assertEquals(1, [SELECT COUNT() FROM Chat_Verification__c WHERE Email__c='shopper@example.com']);
        // not verified until a correct code is entered
        System.assertEquals(false, IdentityService.isVerified('shopper@example.com', null));
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

    @isTest static void sessionVerifiedGatesIdentity() {
        insert new Chat_Verification__c(Email__c='vip@example.com', Code_Hash__c='x',
            Expires_At__c=System.now().addMinutes(5), Verified__c=true, Verified_Until__c=System.now().addMinutes(20), Attempts__c=0);
        System.assertEquals(true, VerificationService.isSessionVerified('vip@example.com'));
        System.assertEquals(true, IdentityService.isVerified('vip@example.com', null), 'Tier-2 OTP verifies');
        System.assertEquals(true, IdentityService.isVerified('VIP@example.com', ''), 'case-insensitive');
        insert new Chat_Verification__c(Email__c='old@example.com', Code_Hash__c='x',
            Expires_At__c=System.now().addMinutes(-30), Verified__c=true, Verified_Until__c=System.now().addMinutes(-1), Attempts__c=0);
        System.assertEquals(false, VerificationService.isSessionVerified('old@example.com'), 'expired window');
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
}
