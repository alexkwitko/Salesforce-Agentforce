@isTest
private class WooCouponServiceTest {
    private class WooCouponMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getMethod() == 'DELETE') {
                res.setStatusCode(200);
                res.setBody('{"deleted":true}');
                return res;
            }
            res.setStatusCode(201);
            res.setBody('{"id":888,"code":"test"}');
            return res;
        }
    }

    @isTest
    static void createsPercentAndFixedCouponsAndDeletes() {
        Test.setMock(HttpCalloutMock.class, new WooCouponMock());

        Test.startTest();
        String percentId = WooCouponService.createPercentCoupon(
            'PCT10',
            10,
            Date.today().addDays(7),
            'shopper@example.com',
            new List<String>{ '56' }
        );
        String fixedId = WooCouponService.createFixedCoupon(
            'CREDIT5',
            5,
            Date.today().addDays(30),
            'shopper@example.com'
        );
        Boolean deleted = WooCouponService.deleteCoupon('888');
        Test.stopTest();

        System.assertEquals('888', percentId, 'percent coupon id returned');
        System.assertEquals('888', fixedId, 'fixed coupon id returned');
        System.assertEquals(true, deleted, 'delete succeeds');
    }

    @isTest
    static void deleteBlankCouponIsSafeNoop() {
        Test.startTest();
        Boolean deleted = WooCouponService.deleteCoupon(null);
        Test.stopTest();

        System.assertEquals(false, deleted, 'blank id is not deleted');
    }
}
