@IsTest
private class CaseMessagingSessionLinkerTest {
    @IsTest
    static void triggerDoesNotFailWhenNoRecentSessionExists() {
        Test.startTest();
        Case c = new Case(
            Origin = 'Chat',
            Status = 'Closed',
            Subject = 'Chat service: Order status answered',
            SuppliedEmail = 'no-session-link@example.com'
        );
        insert c;
        Test.stopTest();

        System.assertNotEquals(null, c.Id, 'chat case insert should not require a matching MessagingSession');
    }

    @IsTest
    static void choosesOnlyUnambiguousLinks() {
        Id caseId = '500000000000001';
        Id sessionId = '0Mw000000000001';
        Map<String, List<Id>> cases = new Map<String, List<Id>>{
            'linked.case@example.com' => new List<Id>{ caseId },
            'multi.session.case@example.com' => new List<Id>{ '500000000000002' },
            'multi.case@example.com' => new List<Id>{ '500000000000003', '500000000000004' }
        };
        Map<String, List<MessagingSession>> sessions = new Map<String, List<MessagingSession>>{
            'linked.case@example.com' => new List<MessagingSession>{
                new MessagingSession(Id = sessionId)
            },
            'multi.session.case@example.com' => new List<MessagingSession>{
                new MessagingSession(Id = '0Mw000000000002'),
                new MessagingSession(Id = '0Mw000000000003')
            },
            'multi.case@example.com' => new List<MessagingSession>{
                new MessagingSession(Id = '0Mw000000000004')
            }
        };

        List<MessagingSession> updates = CaseMessagingSessionLinker.chooseUnambiguousLinks(cases, sessions);

        System.assertEquals(2, updates.size(), 'single-case emails should link even when older unlinked sessions exist');
        System.assertEquals(sessionId, updates[0].Id, 'matched session is updated');
        System.assertEquals(caseId, updates[0].CaseId, 'matched case is linked');
        System.assertEquals('0Mw000000000002', updates[1].Id, 'newest session for the one case is linked');
        System.assertEquals('500000000000002', updates[1].CaseId, 'single case is linked to newest session');
    }

    @IsTest
    static void guestFallbackRequiresOneCaseAndOneGuestSession() {
        Map<String, List<Id>> cases = new Map<String, List<Id>>{
            'verified.guest@example.com' => new List<Id>{ '500000000000005' }
        };
        Map<String, List<MessagingSession>> noEmailSessions = new Map<String, List<MessagingSession>>();

        List<MessagingSession> oneGuest = CaseMessagingSessionLinker.chooseSingleGuestFallback(
            cases,
            noEmailSessions,
            new Set<Id>(),
            new List<MessagingSession>{ new MessagingSession(Id = '0Mw000000000005') }
        );
        System.assertEquals(1, oneGuest.size(), 'one recent guest session can be linked to the one verified guest case');
        System.assertEquals('0Mw000000000005', oneGuest[0].Id);
        System.assertEquals('500000000000005', oneGuest[0].CaseId);

        List<MessagingSession> ambiguousGuests = CaseMessagingSessionLinker.chooseSingleGuestFallback(
            cases,
            noEmailSessions,
            new Set<Id>(),
            new List<MessagingSession>{
                new MessagingSession(Id = '0Mw000000000006'),
                new MessagingSession(Id = '0Mw000000000007')
            }
        );
        System.assertEquals(0, ambiguousGuests.size(), 'multiple recent guest sessions are ambiguous and must not link');
    }

    @IsTest
    static void closestGuestOtpSessionBeatsOlderSignedInSession() {
        Datetime caseTime = Datetime.newInstanceGmt(2026, 6, 15, 9, 42, 29);
        Case otpCase = caseStub('500000000000006', 'alexkwitko@gmail.com', caseTime);
        List<MessagingSession> sessions = new List<MessagingSession>{
            sessionStub('0Mw000000000008', 'alexkwitko@gmail.com', caseTime.addMinutes(-3)),
            sessionStub('0Mw000000000009', null, caseTime.addSeconds(-117)),
            sessionStub('0Mw000000000010', null, caseTime.addSeconds(-50))
        };

        List<MessagingSession> updates = CaseMessagingSessionLinker.chooseClosestLinks(
            new Map<Id, Case>{ otpCase.Id => otpCase },
            new Map<Id, String>{ otpCase.Id => 'alexkwitko@gmail.com' },
            sessions
        );

        System.assertEquals(1, updates.size(), 'the OTP case should link to the active guest session');
        System.assertEquals('0Mw000000000010', updates[0].Id,
            'newest close guest session wins over an older signed-in session with the same email');
        System.assertEquals(otpCase.Id, updates[0].CaseId);
    }

    @IsTest
    static void closestSignedInSessionStillWinsForSignedInService() {
        Datetime caseTime = Datetime.newInstanceGmt(2026, 6, 15, 9, 37, 18);
        Case signedInCase = caseStub('500000000000007', 'alexkwitko@gmail.com', caseTime);
        List<MessagingSession> sessions = new List<MessagingSession>{
            sessionStub('0Mw000000000011', null, caseTime.addSeconds(-28)),
            sessionStub('0Mw000000000012', 'alexkwitko@gmail.com', caseTime.addSeconds(-14))
        };

        List<MessagingSession> updates = CaseMessagingSessionLinker.chooseClosestLinks(
            new Map<Id, Case>{ signedInCase.Id => signedInCase },
            new Map<Id, String>{ signedInCase.Id => 'alexkwitko@gmail.com' },
            sessions
        );

        System.assertEquals(1, updates.size(), 'the signed-in case should link to the signed-in session');
        System.assertEquals('0Mw000000000012', updates[0].Id,
            'email-matched session wins when it is the closest active conversation');
        System.assertEquals(signedInCase.Id, updates[0].CaseId);
    }

    private static Case caseStub(String idValue, String email, Datetime createdDate) {
        return (Case) JSON.deserialize(
            '{"Id":"' + idValue + '","SuppliedEmail":"' + email + '","CreatedDate":"' + iso(createdDate) + '"}',
            Case.class
        );
    }

    private static MessagingSession sessionStub(String idValue, String email, Datetime createdDate) {
        String emailJson = email == null ? 'null' : '"' + email + '"';
        return (MessagingSession) JSON.deserialize(
            '{"Id":"' + idValue + '","Kwitko_Logged_In_Email__c":' + emailJson
                + ',"CreatedDate":"' + iso(createdDate) + '"}',
            MessagingSession.class
        );
    }

    private static String iso(Datetime value) {
        return value.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
    }
}
