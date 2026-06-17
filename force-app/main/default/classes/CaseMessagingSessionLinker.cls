public without sharing class CaseMessagingSessionLinker {
    private static Boolean running = false;
    private static final Integer RECENT_WINDOW_MINUTES = 10;
    private static final Integer GUEST_RECENT_WINDOW_MINUTES = 2;

    public static void afterInsert(List<Case> newCases) {
        if (running || newCases == null || newCases.isEmpty()) return;
        running = true;
        try {
            linkRecentSessions(newCases);
        } catch (Exception e) {
            System.debug('MessagingSession case linker skipped: ' + e.getMessage());
        } finally {
            running = false;
        }
    }

    @TestVisible
    private static void linkRecentSessions(List<Case> newCases) {
        Map<Id, Case> candidatesByCaseId = new Map<Id, Case>();
        Set<Id> accountIds = new Set<Id>();
        for (Case c : newCases) {
            if (c == null || c.Id == null || c.Origin != 'Chat') continue;
            candidatesByCaseId.put(c.Id, c);
            if (String.isBlank(c.SuppliedEmail) && c.AccountId != null) accountIds.add(c.AccountId);
        }
        if (candidatesByCaseId.isEmpty()) return;

        Map<Id, String> emailByAccount = new Map<Id, String>();
        if (!accountIds.isEmpty()) {
            try {
                for (Account a : [
                    SELECT Id, PersonEmail
                    FROM Account
                    WHERE Id IN :accountIds
                ]) {
                    if (String.isNotBlank(a.PersonEmail)) {
                        emailByAccount.put(a.Id, normalizeEmail(a.PersonEmail));
                    }
                }
            } catch (Exception e) {
                System.debug('MessagingSession case linker account lookup skipped: ' + e.getMessage());
            }
        }

        Map<Id, String> emailByCaseId = new Map<Id, String>();
        Set<String> emails = new Set<String>();
        for (Case c : candidatesByCaseId.values()) {
            String email = normalizeEmail(c.SuppliedEmail);
            if (String.isBlank(email) && c.AccountId != null) email = emailByAccount.get(c.AccountId);
            if (String.isBlank(email)) continue;
            emailByCaseId.put(c.Id, email);
            emails.add(email);
        }
        if (emailByCaseId.isEmpty()) return;

        Datetime cutoff = System.now().addMinutes(-RECENT_WINDOW_MINUTES);
        List<MessagingSession> candidateSessions = [
            SELECT Id, Kwitko_Logged_In_Email__c, CreatedDate
            FROM MessagingSession
            WHERE CaseId = null
              AND CreatedDate >= :cutoff
              AND (Kwitko_Logged_In_Email__c IN :emails OR Kwitko_Logged_In_Email__c = null)
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        List<MessagingSession> updates = chooseClosestLinks(candidatesByCaseId, emailByCaseId, candidateSessions);

        if (!updates.isEmpty()) {
            try {
                update updates;
            } catch (Exception e) {
                System.debug('MessagingSession case link failed: ' + e.getMessage());
            }
        }
    }

    @TestVisible
    private static List<MessagingSession> chooseUnambiguousLinks(
        Map<String, List<Id>> caseIdsByEmail,
        Map<String, List<MessagingSession>> sessionsByEmail
    ) {
        List<MessagingSession> updates = new List<MessagingSession>();
        if (caseIdsByEmail == null || sessionsByEmail == null) return updates;
        for (String email : caseIdsByEmail.keySet()) {
            List<Id> caseIds = caseIdsByEmail.get(email);
            List<MessagingSession> sessions = sessionsByEmail.get(email);
            if (caseIds == null || caseIds.size() != 1 || sessions == null || sessions.isEmpty()) {
                continue;
            }
            updates.add(new MessagingSession(Id = sessions[0].Id, CaseId = caseIds[0]));
        }
        return updates;
    }

    @TestVisible
    private static List<MessagingSession> chooseClosestLinks(
        Map<Id, Case> casesById,
        Map<Id, String> emailByCaseId,
        List<MessagingSession> candidateSessions
    ) {
        List<MessagingSession> updates = new List<MessagingSession>();
        if (casesById == null || emailByCaseId == null || candidateSessions == null) return updates;

        Set<Id> usedSessionIds = new Set<Id>();
        List<Case> cases = new List<Case>(casesById.values());
        for (Case c : cases) {
            String email = normalizeEmail(emailByCaseId.get(c.Id));
            if (String.isBlank(email) || c.CreatedDate == null) continue;

            MessagingSession best;
            Integer bestScore;
            Boolean bestEmailMatch = false;
            for (MessagingSession ms : candidateSessions) {
                if (ms == null || ms.Id == null || usedSessionIds.contains(ms.Id) || ms.CreatedDate == null) continue;
                String sessionEmail = normalizeEmail(ms.Kwitko_Logged_In_Email__c);
                Boolean emailMatch = sessionEmail == email;
                Boolean guestMatch = String.isBlank(sessionEmail);
                if (!emailMatch && !guestMatch) continue;

                Long ageMs = c.CreatedDate.getTime() - ms.CreatedDate.getTime();
                if (ageMs < -30000) continue;
                Integer ageSeconds = ageMs < 0 ? 0 : (Integer) (ageMs / 1000);
                if (emailMatch && ageSeconds > RECENT_WINDOW_MINUTES * 60) continue;
                if (guestMatch && ageSeconds > GUEST_RECENT_WINDOW_MINUTES * 60) continue;

                Integer score = ageSeconds + (emailMatch ? 0 : 5);
                if (best == null
                    || score < bestScore
                    || (score == bestScore && emailMatch && !bestEmailMatch)
                ) {
                    best = ms;
                    bestScore = score;
                    bestEmailMatch = emailMatch;
                }
            }

            if (best != null) {
                usedSessionIds.add(best.Id);
                updates.add(new MessagingSession(Id = best.Id, CaseId = c.Id));
            }
        }
        return updates;
    }

    @TestVisible
    private static List<MessagingSession> chooseSingleGuestFallback(
        Map<String, List<Id>> caseIdsByEmail,
        Map<String, List<MessagingSession>> sessionsByEmail,
        Set<Id> alreadyLinkedCaseIds,
        List<MessagingSession> guestSessions
    ) {
        List<MessagingSession> updates = new List<MessagingSession>();
        if (caseIdsByEmail == null || guestSessions == null || guestSessions.size() != 1) return updates;
        List<Id> fallbackCaseIds = new List<Id>();
        for (String email : caseIdsByEmail.keySet()) {
            List<Id> caseIds = caseIdsByEmail.get(email);
            List<MessagingSession> sessions = sessionsByEmail == null ? null : sessionsByEmail.get(email);
            if (caseIds == null || caseIds.size() != 1) continue;
            if (alreadyLinkedCaseIds != null && alreadyLinkedCaseIds.contains(caseIds[0])) continue;
            if (sessions != null && !sessions.isEmpty()) continue;
            fallbackCaseIds.add(caseIds[0]);
        }
        if (fallbackCaseIds.size() == 1) {
            updates.add(new MessagingSession(Id = guestSessions[0].Id, CaseId = fallbackCaseIds[0]));
        }
        return updates;
    }

    private static Set<Id> linkedCaseIds(List<MessagingSession> updates) {
        Set<Id> out = new Set<Id>();
        if (updates == null) return out;
        for (MessagingSession ms : updates) {
            if (ms.CaseId != null) out.add(ms.CaseId);
        }
        return out;
    }

    private static String normalizeEmail(String value) {
        return String.isBlank(value) ? null : value.trim().toLowerCase();
    }
}
