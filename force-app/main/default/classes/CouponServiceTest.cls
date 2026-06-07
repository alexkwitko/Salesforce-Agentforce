@isTest
private class CouponServiceTest {
    @isTest static void issuesCoupon() {
        CouponService.Request r = new CouponService.Request();
        r.email='nobody@example.com'; r.discountPercent=10; r.firstName='Alex';
        Test.startTest();
        CouponService.Result res = CouponService.issue(new List<CouponService.Request>{r})[0];
        Test.stopTest();
        System.assert(res.success, 'should succeed in test (callout skipped)');
        System.assert(res.couponCode.startsWith('KW-ALEX-10-'), 'personalized code: ' + res.couponCode);
    }

    @isTest static void refusesBlockedDiscount() {
        CouponService.Request r = new CouponService.Request();
        r.email='nobody@example.com'; r.discountPercent=0; r.firstName='Alex';
        Test.startTest();
        CouponService.Result res = CouponService.issue(new List<CouponService.Request>{r})[0];
        Test.stopTest();
        System.assertEquals(false, res.success, 'zero percent means the strategy blocked coupon issuance');
        System.assertEquals(null, res.couponCode, 'no coupon should be generated');
        System.assert(res.message.contains('ineligible'), 'message explains the guardrail: ' + res.message);
    }
}
