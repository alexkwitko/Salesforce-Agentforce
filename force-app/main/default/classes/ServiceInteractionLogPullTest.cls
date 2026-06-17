@IsTest
private class ServiceInteractionLogPullTest {
    private class Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            System.assertEquals('POST', req.getMethod());
            System.assert(String.isNotBlank(req.getHeader('X-Kwitko-Signature')), 'request must be HMAC signed');

            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            resp.setStatusCode(200);

            if (req.getEndpoint().contains('/service-interactions/pull')) {
                resp.setBody('{"bridge_version":"test","records":['
                    + '{"id":"ksi_test_1","category":"Returns","message":"I want to return all items from that order","email":"service.logger@example.com","conversationId":"conv-1","token":"tok-1","page":"https://example.test/product","createdAt":"2026-06-16T00:00:00Z","loggedIn":true},'
                    + '{"id":"ksi_dup","category":"Shipping","message":"track it please","email":"service.logger@example.com","conversationId":"conv-1","token":"tok-1","page":"https://example.test/account","createdAt":"2026-06-16T00:01:00Z","loggedIn":true}'
                    + ']}');
            } else if (req.getEndpoint().contains('/service-interactions/ack')) {
                System.assert(req.getBody().contains('ksi_test_1'), 'ack includes created id');
                System.assert(req.getBody().contains('ksi_dup'), 'ack includes duplicate id so Woo does not resend it');
                resp.setBody('{"ok":true,"acked":2}');
            } else {
                resp.setStatusCode(404);
                resp.setBody('{"error":"unexpected"}');
            }
            return resp;
        }
    }

    private class EmptyMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setHeader('Content-Type', 'application/json');
            resp.setStatusCode(200);
            if (req.getEndpoint().contains('/service-interactions/pull')) {
                resp.setBody('{"bridge_version":"test","records":[]}');
            } else {
                resp.setBody('{"ok":true}');
            }
            return resp;
        }
    }

    private static void seedCustomerAndDuplicate() {
        Id personRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account acc = new Account(
            RecordTypeId = personRt,
            FirstName = 'Service',
            LastName = 'Logger',
            PersonEmail = 'service.logger@example.com'
        );
        insert acc;

        insert new Case(
            Status = 'Closed',
            Origin = 'Chat',
            Priority = 'Low',
            Category__c = 'Shipping',
            Subject = 'Existing web turn',
            Service_Interaction_Id__c = 'ksi_dup'
        );
    }

    @IsTest
    static void createsClosedAuditCaseAndSkipsDuplicate() {
        seedCustomerAndDuplicate();

        KwitkoSecrets.overrides.put('WHK_Secret', 'unit-test-secret');
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        ServiceInteractionLogPull.Result result = ServiceInteractionLogPull.runNow();
        Test.stopTest();

        System.assertEquals(2, result.pulled, 'both Woo logs were pulled');
        System.assertEquals(1, result.created, 'only the new service turn creates a case');

        Case created = [
            SELECT Status, Origin, Category__c, Subject, SuppliedEmail, Service_Interaction_Id__c,
                   Resolution__c, Description
            FROM Case
            WHERE Service_Interaction_Id__c = 'ksi_test_1'
            LIMIT 1
        ];
        System.assertEquals('Closed', created.Status);
        System.assertEquals('Chat', created.Origin);
        System.assertEquals('Returns', created.Category__c);
        System.assertEquals('service.logger@example.com', created.SuppliedEmail);
        System.assert(created.Resolution__c.contains('Service chat turn logged'), created.Resolution__c);
        System.assert(created.Description.contains('I want to return all items'), created.Description);

        System.assertEquals(1, [
            SELECT COUNT()
            FROM Task
            WHERE WhatId = :created.Id AND Subject = 'Chat transcript'
        ]);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Case
            WHERE Service_Interaction_Id__c = 'ksi_dup'
        ], 'duplicate id is not inserted again');
    }

    @IsTest
    static void pullJobCreatesClosedAuditCase() {
        seedCustomerAndDuplicate();

        KwitkoSecrets.overrides.put('WHK_Secret', 'unit-test-secret');
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        new ServiceInteractionLogPull.PullJob().execute(null);
        Test.stopTest();

        Case created = [
            SELECT Status, Origin, Category__c, SuppliedEmail, Service_Interaction_Id__c
            FROM Case
            WHERE Service_Interaction_Id__c = 'ksi_test_1'
            LIMIT 1
        ];
        System.assertEquals('Closed', created.Status);
        System.assertEquals('Chat', created.Origin);
        System.assertEquals('Returns', created.Category__c);
        System.assertEquals('service.logger@example.com', created.SuppliedEmail);
    }

    @IsTest
    static void scheduledClassEnqueuesPullJob() {
        KwitkoSecrets.overrides.put('WHK_Secret', 'unit-test-secret');
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        Test.startTest();
        String jobId = System.schedule(
            'ServiceInteractionLogPullTest',
            '0 0 0 1 1 ? 2099',
            new ServiceInteractionLogPull()
        );
        Test.stopTest();

        System.assert(String.isNotBlank(jobId), 'the outer class remains schedulable for existing jobs');
    }
}
