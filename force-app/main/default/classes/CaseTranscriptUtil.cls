public without sharing class CaseTranscriptUtil {
    public static String sanitizePreActionCaseClaims(String chatSummary) {
        if (String.isBlank(chatSummary)) return chatSummary;
        String cleaned = chatSummary.trim();
        cleaned = cleaned.replaceAll(
            '(?i)(^|[\\n\\r\\.?!]\\s*)Case\\s+\\d{6,10}\\s+(?:was\\s+)?(?:created|opened)\\.?',
            '$1'
        );
        cleaned = cleaned.replaceAll(
            '(?i)\\b(otp|verification code|one-time(?: email)? code|code)\\s*[:#=]?\\s*\\(?\\d{6}\\)?',
            '$1 [redacted]'
        );
        cleaned = cleaned.replaceAll('[ \\t]+\\n', '\n').trim();
        return cleaned;
    }

    public static String append(String existing, String chatSummary) {
        if (String.isBlank(chatSummary)) return existing;
        String transcript = sanitizePreActionCaseClaims(chatSummary);
        String combined = (String.isBlank(existing) ? '' : existing.trim() + '\n\n')
            + '--- Chat transcript ---\n' + transcript;
        return combined.length() > 32000 ? combined.substring(0, 32000) : combined;
    }

    public static Id insertSolvedCase(
        Id accountId,
        Id contactId,
        String suppliedEmail,
        Id orderId,
        String wooOrderId,
        String category,
        String subject,
        String resolution,
        String chatSummary
    ) {
        try {
            String cleanResolution = truncate(
                String.isBlank(resolution) ? 'Service interaction completed in chat.' : resolution.trim(),
                4000
            );
            String transcript = String.isBlank(chatSummary)
                ? 'Transcript not provided by agent action.'
                : sanitizePreActionCaseClaims(chatSummary);
            String description = truncate('--- Service resolution ---\n' + cleanResolution
                + '\n\n--- Chat transcript ---\n' + transcript, 32000);
            Case c = new Case(
                AccountId = accountId,
                ContactId = contactId,
                SuppliedEmail = String.isBlank(suppliedEmail) ? null : suppliedEmail.trim(),
                Order__c = orderId,
                Woo_Order_Id__c = String.isBlank(wooOrderId) ? null : wooOrderId.trim(),
                Origin = 'Chat',
                Status = 'Closed',
                Priority = 'Low',
                Category__c = String.isBlank(category) ? 'Service' : category,
                Subject = truncate(String.isBlank(subject) ? 'Chat service interaction resolved' : subject.trim(), 255),
                Summary__c = cleanResolution,
                Description = description,
                Resolution__c = cleanResolution,
                Resolved_By__c = 'Chat Agent (' + UserInfo.getName() + ')'
            );
            insert c;
            insertTaskWithResolution(c.Id, contactId, cleanResolution, transcript);
            return c.Id;
        } catch (Exception e) {
            System.debug('solved service case insert failed: ' + e.getMessage());
            return null;
        }
    }

    public static void insertTask(Id caseId, Id contactId, String chatSummary) {
        if (caseId == null || String.isBlank(chatSummary)) return;
        try {
            String transcript = sanitizePreActionCaseClaims(chatSummary);
            insert new Task(
                WhatId = caseId,
                WhoId = contactId,
                Subject = 'Chat transcript',
                Status = 'Completed',
                Priority = 'Normal',
                ActivityDate = Date.today(),
                Description = transcript.length() > 32000 ? transcript.substring(0, 32000) : transcript
            );
        } catch (Exception e) {
            System.debug('case transcript task failed: ' + e.getMessage());
        }
    }

    public static void insertTaskWithResolution(Id caseId, Id contactId, String resolution, String chatSummary) {
        if (caseId == null) return;
        String cleanResolution = String.isBlank(resolution)
            ? 'Service interaction completed in chat.'
            : truncate(resolution.trim(), 4000);
        String transcript = String.isBlank(chatSummary)
            ? 'Transcript not provided by agent action.'
            : sanitizePreActionCaseClaims(chatSummary);
        String timeline = truncate('--- Service resolution ---\n' + cleanResolution
            + '\n\n--- Chat transcript ---\n' + transcript, 32000);
        insertTask(caseId, contactId, timeline);
    }

    private static String truncate(String value, Integer maxLen) {
        if (value == null || maxLen == null || maxLen <= 0) return value;
        return value.length() > maxLen ? value.substring(0, maxLen) : value;
    }
}
