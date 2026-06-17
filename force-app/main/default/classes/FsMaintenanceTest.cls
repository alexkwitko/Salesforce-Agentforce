@isTest
private class FsMaintenanceTest {
    static final String EMAIL = 'cafe.test@example.com';

    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'Cafe Test'); insert a;
        insert new Contact(LastName = 'Cafe', Email = 'cafe.test@example.com', AccountId = a.Id);
        Product2 p = new Product2(Name = 'Espresso Machine', IsActive = true); insert p;
        insert new Asset(Name = 'Espresso Machine', AccountId = a.Id, Product2Id = p.Id, Status = 'Installed', InstallDate = Date.today());
        insert new ServiceContract(Name = 'Care Plan', AccountId = a.Id, StartDate = Date.today(), EndDate = Date.today().addYears(1));
    }

    // Verified shopper (email == verifiedEmail = Tier-1 signed-in): full happy path.
    @isTest
    static void coverageBookRescheduleCancel() {
        Test.startTest();
        FsGetCoverage.Request cr = new FsGetCoverage.Request(); cr.email = EMAIL; cr.verifiedEmail = EMAIL;
        System.assert(FsGetCoverage.run(new List<FsGetCoverage.Request>{ cr })[0].covered, 'covered');

        FsBookVisit.Request br = new FsBookVisit.Request(); br.email = EMAIL; br.verifiedEmail = EMAIL; br.preferredDate = '2026-09-01';
        System.assert(FsBookVisit.run(new List<FsBookVisit.Request>{ br })[0].success, 'book');

        FsGetVisits.Request vr = new FsGetVisits.Request(); vr.email = EMAIL; vr.verifiedEmail = EMAIL;
        System.assert(FsGetVisits.run(new List<FsGetVisits.Request>{ vr })[0].hasVisits, 'visits');

        FsRescheduleVisit.Request rr = new FsRescheduleVisit.Request(); rr.email = EMAIL; rr.verifiedEmail = EMAIL; rr.newDate = '2026-09-15';
        System.assert(FsRescheduleVisit.run(new List<FsRescheduleVisit.Request>{ rr })[0].success, 'reschedule');

        FsCancelVisit.Request xr = new FsCancelVisit.Request(); xr.email = EMAIL; xr.verifiedEmail = EMAIL;
        System.assert(FsCancelVisit.run(new List<FsCancelVisit.Request>{ xr })[0].success, 'cancel');
        Test.stopTest();
    }

    // SECURITY: unverified (verifiedEmail missing/mismatched) must be refused — no coverage, no booking.
    @isTest
    static void unverifiedIsRefused() {
        Test.startTest();
        FsGetCoverage.Request cr = new FsGetCoverage.Request(); cr.email = EMAIL; // no verifiedEmail
        System.assertEquals(false, FsGetCoverage.run(new List<FsGetCoverage.Request>{ cr })[0].covered, 'no coverage without verification');

        FsGetCoverage.Request cr2 = new FsGetCoverage.Request(); cr2.email = EMAIL; cr2.verifiedEmail = 'someone.else@evil.com';
        System.assertEquals(false, FsGetCoverage.run(new List<FsGetCoverage.Request>{ cr2 })[0].covered, 'mismatched verifiedEmail refused');

        FsBookVisit.Request br = new FsBookVisit.Request(); br.email = EMAIL; // no verifiedEmail
        System.assertEquals(false, FsBookVisit.run(new List<FsBookVisit.Request>{ br })[0].success, 'no booking without verification');

        FsCancelVisit.Request xr = new FsCancelVisit.Request(); xr.email = EMAIL; // no verifiedEmail
        System.assertEquals(false, FsCancelVisit.run(new List<FsCancelVisit.Request>{ xr })[0].success, 'no cancel without verification');
        Test.stopTest();
        // Nothing should have been booked
        System.assertEquals(0, [SELECT COUNT() FROM ServiceAppointment WHERE Account.Name = 'Cafe Test'], 'no appointments created by unverified calls');
    }
}
