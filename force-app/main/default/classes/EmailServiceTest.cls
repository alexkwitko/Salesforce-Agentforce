@isTest
private class EmailServiceTest {

    @isTest static void send_toLead_usesTargetObject() {
        Lead l = new Lead(LastName='T', Company='K', Email='lead@example.com', Email_Consent__c=true);
        insert l;
        EmailService.Request r = new EmailService.Request();
        r.toEmail='lead@example.com'; r.subject='S'; r.htmlBody='<p>x</p>'; r.recordId=l.Id; r.isTransactional=false;
        Test.startTest();
        List<EmailService.Response> out = EmailService.send(new List<EmailService.Request>{ r });
        Test.stopTest();
        System.assertEquals(true, out[0].success, out[0].message);
    }

    @isTest static void send_toContact_usesTargetObject() {
        Contact c = new Contact(LastName='C', Email='c@example.com');
        insert c;
        EmailService.Request r = new EmailService.Request();
        r.toEmail='c@example.com'; r.subject='S'; r.htmlBody='<p>x</p>'; r.recordId=c.Id; r.isTransactional=true;
        Test.startTest();
        List<EmailService.Response> out = EmailService.send(new List<EmailService.Request>{ r });
        Test.stopTest();
        System.assertEquals(true, out[0].success, out[0].message);
    }

    @isTest static void send_rawFallback_andGuards() {
        // raw address (no record) transactional -> setToAddresses fallback
        EmailService.Request tx = new EmailService.Request();
        tx.toEmail='x@example.com'; tx.subject='S'; tx.htmlBody='<p>x</p>'; tx.isTransactional=true;
        // blank recipient
        EmailService.Request noTo = new EmailService.Request();
        noTo.subject='S'; noTo.htmlBody='x'; noTo.isTransactional=true;
        // no consent on a lead
        Lead l = new Lead(LastName='T', Company='K', Email='nc@example.com', Email_Consent__c=false);
        insert l;
        EmailService.Request noConsent = new EmailService.Request();
        noConsent.toEmail='nc@example.com'; noConsent.subject='S'; noConsent.htmlBody='x';
        noConsent.recordId=l.Id; noConsent.isTransactional=false;

        Test.startTest();
        List<EmailService.Response> out = EmailService.send(new List<EmailService.Request>{ tx, noTo, noConsent });
        Test.stopTest();
        System.assertEquals(true,  out[0].success, 'raw transactional sent');
        System.assertEquals(false, out[1].success, 'no recipient');
        System.assertEquals(false, out[2].success, 'no consent blocked');
    }

    @isTest static void transactionalEmailIgnoresMarketingConsent() {
        Lead l = new Lead(LastName='OTP', Company='K', Email='tx-noconsent@example.com', Email_Consent__c=false);
        insert l;

        EmailService.Request tx = new EmailService.Request();
        tx.toEmail = 'tx-noconsent@example.com';
        tx.subject = 'Your Kwitko Coffee verification code';
        tx.htmlBody = '<p>123456</p>';
        tx.recordId = l.Id;
        tx.isTransactional = true;

        EmailService.Request marketing = new EmailService.Request();
        marketing.toEmail = 'tx-noconsent@example.com';
        marketing.subject = 'Coffee offer';
        marketing.htmlBody = '<p>Offer</p>';
        marketing.recordId = l.Id;
        marketing.isTransactional = false;

        Test.startTest();
        List<EmailService.Response> out = EmailService.send(new List<EmailService.Request>{ tx, marketing });
        Test.stopTest();

        System.assertEquals(true, out[0].success, out[0].message);
        System.assertEquals(false, out[1].success, 'marketing must still respect consent');
    }
}
