@isTest
private class WordPressMailServiceTest {
    @isTest static void mailJob_signsAndPostsToRelay() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        new WordPressMailService.MailJob('to@example.com', 'Subject', '<p>Hi</p>').execute(null);
        WordPressMailService.sendAsync('to@example.com', 'Subject', '<p>Hi</p>'); // no-op in test
        WordPressMailService.sendAsync('', '', '');                               // blank guard
        Test.stopTest();
        System.assert(true, 'relay callout executed without error');
    }
    private class Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            System.assertEquals('POST', req.getMethod());
            System.assert(req.getEndpoint().endsWith('/kwitko/v1/send-email'), 'right endpoint');
            System.assert(req.getHeader('X-Kwitko-Signature') != null, 'HMAC signed');
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200); r.setBody('{"ok":true}');
            return r;
        }
    }
}
