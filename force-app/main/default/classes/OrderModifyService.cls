/** OrderModifyService (modify_order) — for a not-yet-shipped order, records a modification request (item/qty
 *  change) as a high-priority case for fulfillment and notes it on the order. Identity-gated. */
public without sharing class OrderModifyService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Requested Change') public String change;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms the requested order change.') public Boolean confirmed;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the order modification conversation so the Case carries the chat trail.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Modify Order' description='Records a modification request (change items/quantities) for a not-yet-shipped order and routes it to fulfillment. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        String displayNo=KwitkoServiceUtil.displayOrderNumber(o);
        String ful=KwitkoServiceUtil.fulfillment(o);
        if(!(new Set<String>{'Not Shipped','Processing'}.contains(ful))){ res.message='Order '+displayNo+' is already '+ful+', so it can no longer be modified. I can start a return instead.'; return res; }
        if(r.confirmed!=true){ res.message='Please confirm the requested change for order '+displayNo+' before I send it to fulfillment.'; return res; }
        String change=String.isBlank(r.change)?'Modification requested via chat':r.change.trim();
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Order__c=o.Id, Woo_Order_Id__c=o.Woo_Order_Id__c, Origin='Chat', Status='New', Priority='High', Category__c='Order',
            Subject='Modify order '+displayNo, Summary__c='Requested change to order '+displayNo+': '+change, Description=CaseTranscriptUtil.append(change, r.chatSummary));
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        CaseTranscriptUtil.insertTask(c.Id, acc.PersonContactId, r.chatSummary);
        update new Order(Id=o.Id, Status_Note__c='Modification requested by Chat Agent on '+System.now().format()+': '+change, Last_Status_Change__c=System.now());
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='modify_order'; lr.stage='Service'; lr.result='Modify '+displayNo+': '+change+' (case '+res.caseNumber+')'; lr.chatSummary=r.chatSummary;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
        res.success=true; res.message='Got it — I opened case '+res.caseNumber+' requesting this change to order '+displayNo+' ('+change+'). Operations still needs to apply the change in WooCommerce before shipment; I have not changed the Woo order directly.';
        return res;
    }
}
