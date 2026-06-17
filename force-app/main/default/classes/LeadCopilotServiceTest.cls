@isTest
private class LeadCopilotServiceTest {

    private static Lead mkLead(String email, Boolean consent) {
        Lead l = new Lead(
            LastName = 'Tester', Company = 'Kwitko', Email = email,
            Status = 'Working - Contacted', Email_Consent__c = consent
        );
        insert l;
        return l;
    }

    @isTest static void markNurture_setsStatusAndDate() {
        Lead l = mkLead('a@example.com', false);
        Test.startTest();
        Integer n = LeadCopilotService.markNurture(new Set<Id>{ l.Id });
        Test.stopTest();
        System.assertEquals(1, n, 'one lead moved');
        Lead after = [SELECT Status, Nurture_Since__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Nurture', after.Status);
        System.assertEquals(Date.today(), after.Nurture_Since__c);
    }

    @isTest static void markNurture_skipsConverted() {
        // a converted lead must not be reopened
        Lead l = mkLead('b@example.com', false);
        LeadCopilotMarkAction.Request req = new LeadCopilotMarkAction.Request();
        req.leadId = l.Id;
        Test.startTest();
        LeadCopilotMarkAction.run(new List<LeadCopilotMarkAction.Request>{ req });
        Test.stopTest();
        System.assertEquals('Nurture', [SELECT Status FROM Lead WHERE Id = :l.Id].Status);
    }

    @isTest static void runStep_recommendationBranches() {
        // cold lead (no metrics) — consent false so we exercise recommend + field write w/o email
        Lead cold = mkLead('cold@example.com', false);
        // high-value lead
        Lead vip = mkLead('vip@example.com', false);
        vip.Lifetime_Order_Value__c = 250; update vip;
        // abandoned cart
        Lead cart = mkLead('cart@example.com', false);
        cart.Cart_Status__c = 'abandoned'; cart.Last_Cart_Value__c = 42.50; update cart;
        // lapsed buyer
        Lead lapsed = mkLead('lapsed@example.com', false);
        lapsed.Last_Purchase_Date__c = Date.today().addMonths(-6); update lapsed;

        Test.startTest();
        LeadCopilotService.StepResult rc = LeadCopilotService.runNurtureStep(cold.Id);
        LeadCopilotService.StepResult rv = LeadCopilotService.runNurtureStep(vip.Id);
        LeadCopilotService.StepResult ra = LeadCopilotService.runNurtureStep(cart.Id);
        LeadCopilotService.StepResult rl = LeadCopilotService.runNurtureStep(lapsed.Id);
        Test.stopTest();

        System.assert(rc.success && String.isNotBlank(rc.nextBestAction), 'cold rec');
        System.assert(rv.nextBestAction.contains('High-value'), 'vip rec: ' + rv.nextBestAction);
        System.assert(ra.nextBestAction.contains('abandoned cart'), 'cart rec: ' + ra.nextBestAction);
        System.assert(rl.nextBestAction.contains('Lapsed'), 'lapsed rec: ' + rl.nextBestAction);
        // recommendation + run date persisted
        Lead after = [SELECT Next_Best_Action__c, Nurture_Last_Run__c FROM Lead WHERE Id = :vip.Id];
        System.assertEquals(Date.today(), after.Nurture_Last_Run__c);
        System.assert(String.isNotBlank(after.Next_Best_Action__c));
    }

    @isTest static void generalNurtureEmail_sentForColdLead() {
        // cold lead (no cart), consent + email -> general nurture email path should send
        Lead cold = mkLead('coldsend@example.com', true);
        cold.FirstName = 'Sam'; update cold;
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        LeadCopilotService.StepResult r = LeadCopilotService.runNurtureStep(cold.Id);
        Test.stopTest();
        System.assert(r.success, 'step succeeded');
        System.assertEquals(true, r.emailSent, 'general nurture email sent: ' + r.message);
    }

    @isTest static void runStep_invocableAndNoLead() {
        Lead l = mkLead('inv@example.com', false);
        LeadCopilotStepAction.Request req = new LeadCopilotStepAction.Request();
        req.leadId = l.Id;
        Test.startTest();
        List<LeadCopilotStepAction.Result> out = LeadCopilotStepAction.run(
            new List<LeadCopilotStepAction.Request>{ req });
        LeadCopilotService.StepResult none = LeadCopilotService.runNurtureStep(null);
        Test.stopTest();
        System.assertEquals(1, out.size());
        System.assert(!none.success, 'null lead -> not success');
    }

    @isTest static void sweep_matchesAgedNurtureLeads() {
        // aged (eligible) — 31 days in nurture, consent + email, not yet run
        Lead aged = mkLead('aged@example.com', true);
        aged.Status = 'Nurture'; aged.Nurture_Since__c = Date.today().addDays(-31);
        update aged;
        // too recent — should NOT match
        Lead fresh = mkLead('fresh@example.com', true);
        fresh.Status = 'Nurture'; fresh.Nurture_Since__c = Date.today().addDays(-5);
        update fresh;

        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        Integer matched = Lead_Copilot_Nurture_Sweep.sweep();
        Test.stopTest();
        System.assertEquals(1, matched, 'only the 31-day-old nurture lead is swept');
    }

    @isTest static void handoff_movesStaleContactedToNurture() {
        // contacted 8 days ago, never converted -> should hand off to Nurture
        Lead stale = mkLead('stale@example.com', false);
        Test.setCreatedDate(stale.Id, Datetime.now().addDays(-8));
        // recently contacted -> should NOT hand off
        Lead recent = mkLead('recent@example.com', false);
        Test.startTest();
        Integer moved = Lead_Copilot_Nurture_Sweep.handoffStaleContacted();
        Test.stopTest();
        System.assertEquals('Nurture', [SELECT Status FROM Lead WHERE Id = :stale.Id].Status, 'stale handed off');
        System.assertEquals('Working - Contacted', [SELECT Status FROM Lead WHERE Id = :recent.Id].Status, 'recent untouched');
        System.assertEquals(1, moved);
    }

    @isTest static void schedulable_runsClean() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        new Lead_Copilot_Nurture_Sweep().execute(null);
        Test.stopTest();
        System.assert(true, 'schedulable executed without error');
    }

    private class Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200); r.setBody('{"ok":true}');
            return r;
        }
    }
}
