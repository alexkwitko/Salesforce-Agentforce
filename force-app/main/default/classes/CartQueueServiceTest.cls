@isTest
private class CartQueueServiceTest {
    private static String lastBody;
    private class Mock implements HttpCalloutMock {
        Integer code; Mock(Integer c){ this.code=c; }
        public HttpResponse respond(HttpRequest req){
            System.assert(req.getHeader('X-Kwitko-Signature') != null, 'HMAC header set');
            lastBody = req.getBody();
            HttpResponse r = new HttpResponse(); r.setStatusCode(code); r.setBody('{}'); return r;
        }
    }
    @isTest static void queueSuccess() {
        KwitkoSecrets.overrides.put('WHK_Secret','unit-secret');
        Test.setMock(HttpCalloutMock.class, new Mock(200));
        CartQueueService.Request ok = new CartQueueService.Request();
        ok.cartToken='tok'; ok.wooProductIdsCsv='12, 34, x'; ok.couponCode='SAVE';
        Test.startTest();
        List<CartQueueService.Result> res = CartQueueService.queue(new List<CartQueueService.Request>{ ok });
        Test.stopTest();
        System.assertEquals(true, res[0].success, res[0].message);
        System.assert(lastBody.contains('"clear":false'), 'cart queue does not clear by default: ' + lastBody);
    }
    @isTest static void queueCanReplaceExistingCartWhenExplicit() {
        KwitkoSecrets.overrides.put('WHK_Secret','unit-secret');
        Test.setMock(HttpCalloutMock.class, new Mock(200));
        CartQueueService.Request ok = new CartQueueService.Request();
        ok.cartToken='tok'; ok.wooProductIdsCsv='12'; ok.replaceExistingCart=true;
        Test.startTest();
        List<CartQueueService.Result> res = CartQueueService.queue(new List<CartQueueService.Request>{ ok });
        Test.stopTest();
        System.assertEquals(true, res[0].success, res[0].message);
        System.assert(lastBody.contains('"clear":true'), 'explicit replace flag reaches storefront: ' + lastBody);
    }
    @isTest static void queueFailAndValidation() {
        KwitkoSecrets.overrides.put('WHK_Secret','unit-secret');
        Test.setMock(HttpCalloutMock.class, new Mock(500));
        CartQueueService.Request ok = new CartQueueService.Request();
        ok.cartToken='tok'; ok.wooProductIdsCsv='99';
        CartQueueService.Request bad = new CartQueueService.Request();
        bad.cartToken=''; bad.wooProductIdsCsv='';
        Test.startTest();
        List<CartQueueService.Result> res = CartQueueService.queue(new List<CartQueueService.Request>{ ok, bad });
        Test.stopTest();
        System.assertEquals(false, res[0].success);
        System.assertEquals(false, res[1].success);
        System.assert(res[1].message.contains('required'));
    }
}
