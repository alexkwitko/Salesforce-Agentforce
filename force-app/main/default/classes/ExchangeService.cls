/** ExchangeService (process_exchange) — for a DELIVERED order, starts a return of the original (refund + label)
 *  and opens an exchange case for the desired replacement item. Identity-gated. */
public without sharing class ExchangeService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Items to Exchange' description='Comma-separated product names the shopper is returning for exchange, or "all"/blank for the whole order.') public String itemsToExchange;
        @InvocableVariable(label='Reason') public String reason;
        @InvocableVariable(label='Desired Item') public String desiredItem;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms this exchange/return.') public Boolean confirmed;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the exchange conversation so the Case carries the chat trail.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Process Exchange' description='Starts a return of a delivered order and opens an exchange case for the desired replacement. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        // Reuse ReturnService for the return leg (it is itself identity-gated + eligibility-checked).
        ReturnService.Request rr=new ReturnService.Request(); rr.email=r.email; rr.verifiedEmail=r.verifiedEmail; rr.orderIdentifier=r.orderIdentifier;
        rr.itemsToReturn=r.itemsToExchange;
        rr.confirmed=r.confirmed;
        rr.reason=String.isBlank(r.reason)?'Exchange':('Exchange: '+r.reason.trim());
        rr.chatSummary=r.chatSummary;
        ReturnService.Result rres=ReturnService.process(new List<ReturnService.Request>{rr})[0];
        if(rres.success!=true){ res.message=rres.message; return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        String want=String.isBlank(r.desiredItem)?'a replacement of the customer choice':r.desiredItem.trim();
        String description='Desired replacement: '+want+'. Return: '+rres.returnOrderNumber+'. Woo replacement fulfillment still needs operations review.';
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Origin='Chat', Status='New', Priority='Medium', Category__c='Returns',
            Subject='Exchange — wants '+want, Summary__c='Exchange request: return '+rres.returnOrderNumber+' created; desired replacement '+want+' requires Woo operations review.', Description=CaseTranscriptUtil.append(description, r.chatSummary));
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        CaseTranscriptUtil.insertTask(c.Id, acc.PersonContactId, r.chatSummary);
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='process_exchange'; lr.stage='Returned'; lr.result='Exchange: return '+rres.returnOrderNumber+', wants '+want+' (case '+res.caseNumber+')';
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
        res.success=true; res.message='I set up the return leg for your exchange ('+rres.returnOrderNumber+'). Case '+res.caseNumber+' is open for operations to arrange the WooCommerce replacement for '+want+'; no replacement has shipped yet.';
        return res;
    }
}
