@isTest
private class CaseTranscriptUtilTest {
    @isTest
    static void sanitizeAndAppendStripOnlyPreActionCaseClaims() {
        String raw = 'Shopper asked for help. Prior open case: 00001061 (Returns, New). Case 00001071 created. Verified identity with a one-time email code (216908).';

        String sanitized = CaseTranscriptUtil.sanitizePreActionCaseClaims(raw);

        System.assert(sanitized.contains('Prior open case: 00001061'), sanitized);
        System.assert(!sanitized.contains('Case 00001071 created'), sanitized);
        System.assert(sanitized.contains('one-time email code [redacted]'), sanitized);
        System.assert(!sanitized.contains('216908'), sanitized);
        System.assertEquals(null, CaseTranscriptUtil.sanitizePreActionCaseClaims(null), 'null stays null');

        String appended = CaseTranscriptUtil.append('Issue detail', raw);
        System.assert(appended.contains('Issue detail'), appended);
        System.assert(appended.contains('Chat transcript'), appended);
        System.assert(!appended.contains('Case 00001071 created'), appended);
        System.assert(!appended.contains('216908'), appended);
    }

    @isTest
    static void insertSolvedCaseStoresSanitizedTranscriptAndTask() {
        String rawTranscript = 'Shopper asked for order status. Verification code: 216908. Case 00001071 opened.';

        Id caseId = CaseTranscriptUtil.insertSolvedCase(
            null,
            null,
            'shopper@example.com',
            null,
            '506',
            'Order',
            'Chat service: Order status answered',
            'Order #506 was delivered.',
            rawTranscript
        );

        System.assertNotEquals(null, caseId, 'helper returns the created case id');
        Case c = [
            SELECT Status, SuppliedEmail, Woo_Order_Id__c, Description, Resolution__c
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];
        System.assertEquals('Closed', c.Status, 'solved helper creates closed cases');
        System.assertEquals('shopper@example.com', c.SuppliedEmail, 'supplied email is retained');
        System.assertEquals('506', c.Woo_Order_Id__c, 'Woo order id is retained');
        System.assert(c.Description.contains('Order #506 was delivered.'), c.Description);
        System.assert(!c.Description.contains('Case 00001071 opened'), c.Description);
        System.assert(c.Description.contains('Verification code [redacted]'), c.Description);
        System.assert(!c.Description.contains('216908'), c.Description);
        System.assertEquals('Order #506 was delivered.', c.Resolution__c, 'resolution is stored');

        Task transcript = [
            SELECT Description
            FROM Task
            WHERE WhatId = :caseId AND Subject = 'Chat transcript'
            LIMIT 1
        ];
        System.assert(transcript.Description.contains('Service resolution'), transcript.Description);
        System.assert(transcript.Description.contains('Order #506 was delivered.'), transcript.Description);
        System.assert(transcript.Description.contains('Shopper asked for order status'), transcript.Description);
        System.assert(!transcript.Description.contains('Case 00001071 opened'), transcript.Description);
        System.assert(!transcript.Description.contains('216908'), transcript.Description);

        CaseTranscriptUtil.insertTask(null, null, 'ignored');
        CaseTranscriptUtil.insertTask(caseId, null, '');
    }
}
