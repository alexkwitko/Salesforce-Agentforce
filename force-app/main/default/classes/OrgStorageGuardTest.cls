@isTest
private class OrgStorageGuardTest {

    @isTest static void belowThreshold_noAction() {
        // Developer Edition orgs can report full storage even in test context.
        // Put the test-only threshold above a full 1.00 ratio to exercise the
        // no-action branch deterministically without depending on live storage.
        OrgStorageGuard.TRIGGER_FRACTION = 1.01;
        Test.startTest();
        String r = OrgStorageGuard.run();
        Test.stopTest();
        System.assert(r.contains('below threshold'), r);
    }

    @isTest static void belowThreshold_stillPurgesExpiredOtp() {
        insert new List<Chat_Verification__c>{
            new Chat_Verification__c(
                Email__c = 'expired-low-pressure@example.com',
                Expires_At__c = System.now().addMinutes(-5)
            ),
            new Chat_Verification__c(
                Email__c = 'current-low-pressure@example.com',
                Expires_At__c = System.now().addMinutes(5)
            )
        };

        OrgStorageGuard.TRIGGER_FRACTION = 1.01;
        Test.startTest();
        String r = OrgStorageGuard.run();
        Test.stopTest();

        System.assert(r.contains('below threshold'), r);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'expired-low-pressure@example.com'
        ], 'expired OTP rows should be purged even below the storage threshold');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'current-low-pressure@example.com'
        ], 'non-expired OTP rows should be preserved below the storage threshold');
    }

    @isTest static void overThreshold_runsPurge() {
        // Force the guard to act; with no purgeable rows present it still
        // exercises the full over-threshold path.
        OrgStorageGuard.TRIGGER_FRACTION = -1;
        Test.startTest();
        String r = OrgStorageGuard.run();
        Test.stopTest();
        System.assert(r.contains('purged'), r);
    }

    @isTest static void overThreshold_purgesExpiredOtpButKeepsCurrentOtp() {
        insert new List<Chat_Verification__c>{
            new Chat_Verification__c(
                Email__c = 'expired-storage-guard@example.com',
                Expires_At__c = System.now().addMinutes(-5)
            ),
            new Chat_Verification__c(
                Email__c = 'current-storage-guard@example.com',
                Expires_At__c = System.now().addMinutes(5)
            )
        };

        OrgStorageGuard.TRIGGER_FRACTION = -1;
        Test.startTest();
        String r = OrgStorageGuard.run();
        Test.stopTest();

        System.assert(r.contains('purged'), r);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'expired-storage-guard@example.com'
        ], 'expired OTP rows should be purged');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Chat_Verification__c
            WHERE Email__c = 'current-storage-guard@example.com'
        ], 'non-expired OTP rows should be preserved');
    }

    @isTest static void purge_deletesAndEmptiesBin() {
        Task t = new Task(Subject = 'OrgStorageGuard temp');
        insert t;
        Test.startTest();
        Integer n = OrgStorageGuard.purge(new List<SObject>{ t });
        Test.stopTest();
        System.assertEquals(1, n, 'one test task should be purged');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE Id = :t.Id], 'purged task should not remain active');
    }

    @isTest static void purgeDeletedRows_handlesEmptyAndInvalidObjects() {
        Test.startTest();
        Integer n = OrgStorageGuard.purgeDeletedRows(new List<String>{ 'Task', 'Nope__c' });
        Test.stopTest();
        System.assertEquals(0, n, 'empty and non-allowlisted recycle-bin requests should be no-ops');
    }

    @isTest static void scheduleDefault_registersJobs() {
        Test.startTest();
        String ids = OrgStorageGuard.scheduleDefault();
        Test.stopTest();
        System.assertNotEquals(null, ids, 'scheduleDefault should return job ids');
        System.assertEquals(4, ids.split(',').size(), ids);
        System.assertEquals(4, [SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'OrgStorageGuard-%']);
        // names are zero-padded quarter-hours
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name = 'OrgStorageGuard-45'], '45-minute job should be registered');
    }
}
