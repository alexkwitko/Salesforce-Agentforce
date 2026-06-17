/**
 * JourneyLogger
 * Invocable wrapper for journey logging (Apex allows only one @InvocableMethod per class,
 * so this is split from JourneyService). The orchestrator/agents call this after each action
 * to record what happened and update journey memory.
 */
public without sharing class JourneyLogger {

    public class LogRequest {
        @InvocableVariable(label='Email' description='Customer email (journey key).' required=true)
        public String email;
        @InvocableVariable(label='Agent') public String agent;
        @InvocableVariable(label='Action') public String action;
        @InvocableVariable(label='Product Ids (csv)') public String productIds;
        @InvocableVariable(label='Order Id') public String orderId;
        @InvocableVariable(label='Result') public String result;
        @InvocableVariable(label='Stage') public String stage;
        @InvocableVariable(label='Add Recommended Product Ids (csv)') public String addRecommendedProductIds;
        @InvocableVariable(label='Mark Post-Purchase Done Order Id') public String markPostPurchaseDoneOrderId;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the service chat so a Case can retain what happened.')
        public String chatSummary;
    }

    @InvocableMethod(label='Log Agent Interaction'
        description='Append an interaction to the journey log and update journey memory (recommended ids, post-purchase-done orders, stage). Call after each agent action.')
    public static List<String> logInteraction(List<LogRequest> reqs) {
        List<String> out = new List<String>();
        for (LogRequest r : reqs) {
            out.add(JourneyService.recordInteraction(r.email, r.agent, r.action, r.productIds,
                r.orderId, r.result, r.stage, r.addRecommendedProductIds, r.markPostPurchaseDoneOrderId,
                r.chatSummary));
        }
        return out;
    }
}
