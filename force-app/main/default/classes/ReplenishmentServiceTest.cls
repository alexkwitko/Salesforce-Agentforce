@isTest
private class ReplenishmentServiceTest {
    static Id personRt(){ return [SELECT Id FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id; }
    @isTest static void sendsWhenDue() {
        Account a = new Account(FirstName='Alex', LastName='Reorder', PersonEmail='reorder@test.com',
            RecordTypeId=personRt(), Email_Consent__c=true,
            Insights_Avg_Days_Between_Orders__c=30, Insights_Days_Since_Last_Order__c=35,
            Insights_Taste_Profile__c='Roast: Dark (70%) | Bean: Single-Origin (60%)');
        insert a;
        Test.startTest(); String res = ReplenishmentService.run(); Test.stopTest();
        System.assert(res.contains('1 '), res);
        Account got=[SELECT Insights_Last_Replenish_Email__c FROM Account WHERE Id=:a.Id];
        System.assertEquals(Date.today(), got.Insights_Last_Replenish_Email__c, 'stamped');
        System.assertEquals('Dark roast', ReplenishmentService.favorite('Roast: Dark (70%) | x'));
        System.assertEquals(null, ReplenishmentService.favorite(''));
        System.assert(ReplenishmentService.body(a).contains('Alex'));
    }
    @isTest static void skipsWhenNotDue() {
        Account a = new Account(FirstName='No', LastName='Yet', PersonEmail='notyet@test.com',
            RecordTypeId=personRt(), Email_Consent__c=true,
            Insights_Avg_Days_Between_Orders__c=30, Insights_Days_Since_Last_Order__c=5);
        insert a;
        Test.startTest(); ReplenishmentService.run(); Test.stopTest();
        System.assertEquals(null, [SELECT Insights_Last_Replenish_Email__c FROM Account WHERE Id=:a.Id].Insights_Last_Replenish_Email__c);
    }
    @isTest static void schedules(){ Test.startTest(); System.assertNotEquals(null, ReplenishmentService.scheduleDaily()); Test.stopTest(); }
}
