@isTest
private class WebIdentityServiceTest {
    private class MockOk implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            System.assertEquals('POST', req.getMethod());
            System.assert(req.getHeader('X-Kwitko-Signature') != null, 'must be HMAC-signed');
            System.assert(req.getEndpoint().endsWith('/wp-json/kwitko/v1/identify'), 'identify endpoint');
            r.setStatusCode(200); r.setBody('{"ok":true}'); return r;
        }
    }
    private class MockErr implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse(); r.setStatusCode(500); r.setBody('err'); return r;
        }
    }
    @isTest static void testBlankInputsFail() {
        WebIdentityService.Request bad = new WebIdentityService.Request();
        List<WebIdentityService.Result> r = WebIdentityService.link(new List<WebIdentityService.Request>{ bad });
        System.assertEquals(false, r[0].success);
    }
    @isTest static void testHappyPath() {
        Test.setMock(HttpCalloutMock.class, new MockOk());
        WebIdentityService.Request ok = new WebIdentityService.Request();
        ok.cartToken = 'tok_123'; ok.verifiedEmail = 'Alex@Example.com'; ok.firstName = 'Alex';
        Test.startTest();
        List<WebIdentityService.Result> r = WebIdentityService.link(new List<WebIdentityService.Request>{ ok });
        Test.stopTest();
        System.assertEquals(true, r[0].success, 'mocked 200 => success');
    }
    @isTest static void testCalloutError() {
        Test.setMock(HttpCalloutMock.class, new MockErr());
        WebIdentityService.Request ok = new WebIdentityService.Request();
        ok.cartToken = 'tok_123'; ok.verifiedEmail = 'a@b.com';
        Test.startTest();
        List<WebIdentityService.Result> r = WebIdentityService.link(new List<WebIdentityService.Request>{ ok });
        Test.stopTest();
        System.assertEquals(false, r[0].success, 'mocked 500 => failure');
    }
}
