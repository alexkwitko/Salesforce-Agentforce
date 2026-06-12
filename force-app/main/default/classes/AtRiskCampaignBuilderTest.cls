@isTest
private class AtRiskCampaignBuilderTest {

    private static Id personRt() {
        return [SELECT Id FROM RecordType
                WHERE SobjectType='Account' AND IsPersonType=true LIMIT 1].Id;
    }

    // person account pre-scored so we test the builder in isolation
    private static Account scored(String last, Decimal churn, Decimal ltv, String tier, Boolean consent) {
        Account a = new Account(RecordTypeId=personRt(), FirstName='T', LastName=last,
            PersonEmail=last+'@test.com', Email_Consent__c=consent,
            Churn_Score__c=churn, Predicted_LTV__c=ltv, Churn_Risk_Tier__c=tier,
            Last_Scored__c=System.now());
        insert a;
        return [SELECT Id, PersonContactId, Value_At_Risk__c FROM Account WHERE Id=:a.Id];
    }

    @isTest static void testModelScoreOverridesHeuristic() {
        // Heuristic says NOT at risk (0.20), but the Einstein model score written back says it IS
        // (0.92). The win-back must select on the model score.
        Account a = scored('ModelSays', 0.20, 400, 'C', true);
        a.Data_Cloud_Churn_Risk__c = '0.92 (AI model v2)';
        update a;

        Test.startTest();
        Integer added = AtRiskCampaignBuilder.run();
        Test.stopTest();

        System.assertEquals(1, added, 'model score 0.92 must qualify the account the heuristic missed');
        Campaign c = [SELECT Id, (SELECT ContactId FROM CampaignMembers)
                      FROM Campaign WHERE Name=:AtRiskCampaignBuilder.CAMPAIGN_NAME LIMIT 1];
        System.assertEquals(a.PersonContactId, c.CampaignMembers[0].ContactId, 'the model-flagged account is the member');
    }

    @isTest static void testHeuristicUsedWhenNoModelScore() {
        // No model score on file -> falls back to the heuristic (low churn -> excluded).
        scored('NoModel', 0.20, 600, 'C', true);
        Test.startTest();
        Integer added = AtRiskCampaignBuilder.run();
        Test.stopTest();
        System.assertEquals(0, added, 'no model score + low heuristic churn -> not selected');
    }

    @isTest static void testBuildAndTier() {
        Account tierA = scored('TopRisk', 0.90, 400, 'A', true);   // VAR 360 -> Tier A -> task
        Account tierB = scored('MidRisk', 0.75, 250, 'B', true);   // qualifies, no task
        Account notConsented = scored('NoConsent', 0.95, 500, 'A', false); // filtered out
        Account lowRisk = scored('Safe', 0.20, 600, 'C', true);    // below churn min

        Test.startTest();
        Integer added = AtRiskCampaignBuilder.run();
        Test.stopTest();

        System.assertEquals(2, added, 'only the two consented, high-risk, high-value buyers');
        Campaign c = [SELECT Id, (SELECT ContactId FROM CampaignMembers)
                      FROM Campaign WHERE Name=:AtRiskCampaignBuilder.CAMPAIGN_NAME LIMIT 1];
        System.assertEquals(2, c.CampaignMembers.size(), 'two members on the campaign');

        List<Task> tasks = [SELECT Id, WhoId FROM Task WHERE WhoId=:tierA.PersonContactId];
        System.assertEquals(1, tasks.size(), 'Tier A gets a human follow-up task');
        List<Task> none = [SELECT Id FROM Task WHERE WhoId=:tierB.PersonContactId];
        System.assertEquals(0, none.size(), 'Tier B is automated, no task');
    }

    @isTest static void testIdempotent() {
        scored('Repeat', 0.85, 300, 'A', true);
        Test.startTest();
        Integer first = AtRiskCampaignBuilder.run();
        Integer second = AtRiskCampaignBuilder.run();
        Test.stopTest();
        System.assertEquals(1, first, 'one member added first run');
        System.assertEquals(0, second, 'no duplicate on second run');
    }

    @isTest static void testWinBackSendOnceOnly() {
        scored('WinBack', 0.85, 300, 'A', true);
        Test.startTest();
        AtRiskCampaignBuilder.run();
        Integer sent1 = AtRiskCampaignBuilder.sendWinBack();
        Integer sent2 = AtRiskCampaignBuilder.sendWinBack();
        Test.stopTest();
        System.assertEquals(1, sent1, 'win-back email sent to the new member');
        System.assertEquals(0, sent2, 'never re-sent — Emailed status is the gate');
        List<CampaignMember> cms = [SELECT Status FROM CampaignMember
            WHERE Campaign.Name = :AtRiskCampaignBuilder.CAMPAIGN_NAME];
        System.assertEquals('Emailed', cms[0].Status, 'member marked Emailed');
    }

    @isTest static void testWinBackRespectsConsentRevocation() {
        Account a = scored('Revoked', 0.85, 300, 'A', true);
        Test.startTest();
        AtRiskCampaignBuilder.run();
        a.Email_Consent__c = false;  // consent revoked AFTER selection, BEFORE send
        update a;
        Integer sent = AtRiskCampaignBuilder.sendWinBack();
        Test.stopTest();
        System.assertEquals(0, sent, 'EmailService consent re-check blocks the send');
    }
}
